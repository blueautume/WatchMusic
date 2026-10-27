import Foundation

struct LANReceptionStatus {
    let fileName: String
    let completedBytes: Int64
    let totalBytes: Int64
    let fileIndex: Int
    let fileCount: Int
    let isSaving: Bool
}

/// Cancellation and the final rename have a single ordering. A cancellation
/// cannot report success and then allow a worker to publish the file later.
final class LANStoragePermission {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false

    @discardableResult func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !committed else { return false }
        cancelled = true
        return true
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func commit(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try action()
        committed = true
    }

    var didCommit: Bool {
        lock.lock(); defer { lock.unlock() }
        return committed
    }
}

/// Only HTTP URLSession requests run on the watch. Discovery and the transfer
/// manifest arrive over the already paired WatchConnectivity session.
final class LANDownloadReceiver: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    var onUpdate: ((LANReceptionStatus?) -> Void)?
    var onEvent: ((LANTransferEvent) -> Void)?
    private let stateQueue = DispatchQueue(label: "com.offlinewatchplayer.lab.lan-download")
    private let validationQueue = DispatchQueue(label: "com.offlinewatchplayer.lab.lan-validation", qos: .utility)
    private let storeFile: (URL, LANTransferFile, LANStoragePermission) throws -> Void
    private let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LANIncoming", isDirectory: true)
    private var networkSession: URLSession?
    private var offer: LANTransferOffer?
    private var pending: [LANTransferFile] = []
    private var current: LANTransferFile?
    private var currentTask: URLSessionDownloadTask?
    private var storagePermission: LANStoragePermission?
    private var baseIndex = 0
    private var finishedCount = 0
    private var lastProgressTime: TimeInterval = 0
    private var currentBytes: Int64 = 0
    private var generation = UUID()

    init(storeFile: @escaping (URL, LANTransferFile, LANStoragePermission) throws -> Void) {
        self.storeFile = storeFile
        super.init()
        // A force-quit can leave a verified-but-not-committed temporary file.
        // There is only one receiver per process, so startup can discard it.
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    func accept(_ incoming: LANTransferOffer, allowLoopbackForTesting: Bool = false) throws {
        try LANTransferValidation.validate(incoming, allowLoopback: allowLoopbackForTesting)
        try stateQueue.sync {
            guard offer == nil else { throw receiverError("正在接收另一批歌曲，请完成或取消后重试。") }
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.allowsCellularAccess = false
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = min(900, max(10, incoming.expiresAt.timeIntervalSinceNow))
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.httpMaximumConnectionsPerHost = 1
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = stateQueue
            networkSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            offer = incoming
            pending = incoming.files
            finishedCount = 0
            generation = UUID()
            let thisGeneration = generation
            stateQueue.asyncAfter(deadline: .now() + incoming.expiresAt.timeIntervalSinceNow) { [weak self] in
                guard let self, self.offer != nil, self.generation == thisGeneration else { return }
                self.stopOnQueue(kind: .failed, message: "传输会话已过期，请从手机重试。")
            }
            beginNext()
        }
    }

    func handle(_ command: LANTransferCommand) {
        stateQueue.async { [weak self] in
            guard let self, self.offer?.sessionID == command.sessionID else { return }
            switch command.kind {
            case .stop: self.stopOnQueue(kind: .cancelled, message: "手机已停止局域网传输。")
            case .cancel:
                guard let id = command.fileID else { return }
                self.cancelOnQueue(fileID: id)
            }
        }
    }

    func stop(message: String = "已取消局域网传输。") {
        stateQueue.async { [weak self] in self?.stopOnQueue(kind: .cancelled, message: message) }
    }

    private func beginNext() {
        guard let offer else { return }
        guard offer.expiresAt > Date() else { stopOnQueue(kind: .failed, message: "传输会话已过期，请从手机重试。"); return }
        guard !pending.isEmpty else { finishSession(); return }
        current = pending.removeFirst()
        storagePermission = LANStoragePermission()
        baseIndex = 0
        currentBytes = 0
        lastProgressTime = 0
        startCurrentRequest()
    }

    private func startCurrentRequest() {
        guard let offer, let file = current, let session = networkSession else { return }
        let url = offer.baseURLs[baseIndex].appendingPathComponent("v1/files").appendingPathComponent(file.id)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + offer.token, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        currentBytes = 0
        publish(saving: false)
        emit(kind: .progress, file: file, completed: 0, message: nil)
        let task = session.downloadTask(with: request)
        currentTask = task
        task.resume()
    }

    private func retryOrFail(_ error: Error, mayTryAnotherAddress: Bool) {
        guard let offer, current != nil else { return }
        currentTask = nil
        // Once bytes have been reported, fail explicitly rather than silently
        // restarting at zero and making the phone's progress misleading.
        if mayTryAnotherAddress, currentBytes == 0, baseIndex + 1 < offer.baseURLs.count, offer.expiresAt > Date() {
            baseIndex += 1
            startCurrentRequest()
        } else { finishCurrent(kind: .failed, message: error.localizedDescription) }
    }

    private func finishCurrent(kind: LANTransferEvent.Kind, message: String?) {
        guard let file = current else { return }
        emit(kind: kind, file: file, completed: kind == .stored ? file.byteCount : currentBytes, message: message)
        currentTask = nil
        storagePermission = nil
        current = nil
        finishedCount += 1
        beginNext()
    }

    private func cancelOnQueue(fileID: String) {
        if current?.id == fileID {
            guard storagePermission?.cancel() != false else { return }
            currentTask?.cancel()
            finishCurrent(kind: .cancelled, message: "已取消")
        } else if let index = pending.firstIndex(where: { $0.id == fileID }) {
            let file = pending.remove(at: index)
            finishedCount += 1
            emit(kind: .cancelled, file: file, completed: 0, message: "已取消")
            if current != nil { publish(saving: currentTask == nil) }
        }
    }

    private func stopOnQueue(kind: LANTransferEvent.Kind, message: String) {
        guard offer != nil else { return }
        if let file = current {
            let alreadyStored = storagePermission?.cancel() == false
            currentTask?.cancel()
            emit(kind: alreadyStored ? .stored : kind, file: file,
                 completed: alreadyStored ? file.byteCount : currentBytes,
                 message: alreadyStored ? "歌曲已保存到手表" : message)
        }
        for file in pending { emit(kind: kind, file: file, completed: 0, message: message) }
        finishSession()
    }

    private func finishSession() {
        generation = UUID()
        currentTask?.cancel()
        currentTask = nil
        current = nil
        pending = []
        storagePermission = nil
        offer = nil
        let oldSession = networkSession
        networkSession = nil
        oldSession?.invalidateAndCancel()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(nil) }
    }

    private func publish(saving: Bool) {
        guard let file = current, let offer else { return }
        let status = LANReceptionStatus(fileName: file.fileName, completedBytes: currentBytes,
                                        totalBytes: file.byteCount, fileIndex: finishedCount + 1,
                                        fileCount: offer.files.count, isSaving: saving)
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(status) }
    }

    private func emit(kind: LANTransferEvent.Kind, file: LANTransferFile, completed: Int64, message: String?) {
        guard let offer else { return }
        let event = LANTransferEvent(sessionID: offer.sessionID, fileID: file.id, kind: kind,
                                     completedBytes: max(0, min(file.byteCount, completed)),
                                     totalBytes: file.byteCount, message: message)
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard session === networkSession, downloadTask === currentTask, let file = current else { return }
        guard totalBytesWritten <= file.byteCount else {
            downloadTask.cancel()
            finishCurrent(kind: .failed, message: "接收大小超出歌曲清单，已停止。")
            return
        }
        currentBytes = max(0, totalBytesWritten)
        publish(saving: false)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressTime >= 1 || currentBytes == file.byteCount {
            lastProgressTime = now
            emit(kind: .progress, file: file, completed: currentBytes, message: nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard session === networkSession, downloadTask === currentTask, let file = current,
              let permission = storagePermission else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            retryOrFail(receiverError("局域网下载失败（HTTP \(code)）。"), mayTryAnotherAddress: code >= 500 || code == 0)
            return
        }
        do {
            let bytes = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(bytes) == file.byteCount else {
                finishCurrent(kind: .failed, message: "接收的歌曲大小不符，请重新发送。")
                return
            }
        } catch { finishCurrent(kind: .failed, message: "无法检查下载文件：\(error.localizedDescription)"); return }
        // URLSession deletes its download location when this callback returns.
        let temporary = stagingRoot.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: temporary) }
        catch { finishCurrent(kind: .failed, message: "无法保存下载临时文件：\(error.localizedDescription)"); return }
        currentTask = nil
        currentBytes = file.byteCount
        emit(kind: .progress, file: file, completed: file.byteCount, message: "正在校验并保存")
        publish(saving: true)
        let thisGeneration = generation
        validationQueue.async { [weak self] in
            guard let self else { try? FileManager.default.removeItem(at: temporary); return }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let result = Result { try self.storeFile(temporary, file, permission) }
            self.stateQueue.async {
                guard self.generation == thisGeneration, self.current?.id == file.id,
                      self.storagePermission === permission else { return }
                switch result {
                case .success: self.finishCurrent(kind: .stored, message: "歌曲已保存到手表")
                case .failure(let error):
                    self.finishCurrent(kind: error is CancellationError ? .cancelled : .failed, message: error.localizedDescription)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === networkSession, task === currentTask else { return }
        if let error { retryOrFail(error, mayTryAnotherAddress: (error as NSError).code != NSURLErrorCancelled) }
        else { finishCurrent(kind: .failed, message: "下载没有返回可保存的歌曲文件。") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the one-session token to a redirect destination.
        completionHandler(nil)
    }

    private func receiverError(_ message: String) -> NSError {
        NSError(domain: "LANDownloadReceiver", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
