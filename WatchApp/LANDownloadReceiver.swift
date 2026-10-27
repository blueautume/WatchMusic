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

/// URLSession's daemon owns the network work; the application only keeps a
/// durable manifest, completed download files, and an idempotent receipt outbox.
final class LANDownloadReceiver: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    static var backgroundSessionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.offlinewatchplayer.lab") + ".lan-download.v2"
    }

    var onUpdate: ((LANReceptionStatus?) -> Void)?
    var onEvent: ((LANTransferEvent) -> Void)?
    private let stateQueue = DispatchQueue(label: "com.offlinewatchplayer.lab.lan-download")
    private let validationQueue = DispatchQueue(label: "com.offlinewatchplayer.lab.lan-validation", qos: .utility)
    private let storeFile: (URL, LANTransferFile, LANStoragePermission) throws -> Void
    private let root: URL
    private let stagingRoot: URL
    private let snapshotURL: URL
    private let outboxURL: URL
    private var networkSession: URLSession?
    private var state: LANBackgroundTransferState?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var missingRestoredFiles = Set<String>()
    private var permissions: [String: LANStoragePermission] = [:]
    private var deliveryBarrier = LANBackgroundDeliveryBarrier()
    private var outbox = LANBackgroundReceiptOutbox()
    private var needsTerminalJournalRepair = false
    private var lastProgressTime: [String: TimeInterval] = [:]
    private var lastSnapshotTime: TimeInterval = 0
    private var generation = UUID()
    private var didRestore = false
    private var backgroundCompletions: [() -> Void] = []
    private var isForeground = false

    var pendingFileIDs: Set<String> { stateQueue.sync { state?.pendingFileIDs ?? [] } }

    init(storeFile: @escaping (URL, LANTransferFile, LANStoragePermission) throws -> Void) {
        self.storeFile = storeFile
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LANBackground-v2", isDirectory: true)
        stagingRoot = root.appendingPathComponent("Incoming", isDirectory: true)
        snapshotURL = root.appendingPathComponent("transfer.json")
        outboxURL = root.appendingPathComponent("receipts.json")
        super.init()
    }

    /// Configure callbacks before calling this once during application startup.
    /// Main-queue callbacks cannot run until the caller has restored its identity.
    @discardableResult func restore() -> LANTransferOffer? {
        stateQueue.sync {
            restoreOnQueue()
            return state?.offer
        }
    }

    func setForeground(_ value: Bool) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.isForeground && !value { self.deliveryBarrier.beginDelivery() }
            self.isForeground = value
            if value { self.resumeUnsubmittedIntents() }
        }
    }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        stateQueue.async { [weak self] in
            guard let self, identifier == Self.backgroundSessionIdentifier else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            self.restoreOnQueue()
            self.backgroundCompletions.append(completion)
            self.completeBackgroundEventsIfReady()
        }
    }

    func replayTerminalEvents() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.restoreOnQueue()
            for event in self.outbox.events { self.deliver(event) }
        }
    }

    func acknowledgeTerminalEvent(sessionID: String, fileID: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            // If the outbox write succeeded but the terminal manifest write
            // failed, retain the receipt until no stale pending intent remains.
            if self.needsTerminalJournalRepair {
                do {
                    if self.state != nil { try self.persistState() }
                    else {
                        if FileManager.default.fileExists(atPath: self.snapshotURL.path) {
                            try FileManager.default.removeItem(at: self.snapshotURL)
                        }
                        self.needsTerminalJournalRepair = false
                    }
                } catch { return }
            }
            self.outbox.acknowledge(sessionID: sessionID, fileID: fileID)
            try? self.persistOutbox()
        }
    }

    func accept(_ incoming: LANTransferOffer, allowLoopbackForTesting: Bool = false) throws {
        try LANTransferValidation.validate(incoming, allowLoopback: allowLoopbackForTesting)
        try stateQueue.sync {
            restoreOnQueue()
            guard state == nil else { throw receiverError("正在接收另一批歌曲，请完成或取消后重试。") }
            guard outbox.count + incoming.files.count <= 2_000 else { throw receiverError("请先连接手机同步接收结果后重试。") }
            try ensureDirectories()
            generation = UUID()
            state = LANBackgroundTransferState(offer: incoming, allowsLoopbackForTesting: allowLoopbackForTesting)
            tasks = [:]
            missingRestoredFiles = []
            permissions = [:]
            lastProgressTime = [:]
            deliveryBarrier.beginDelivery()
            do {
                // Persist intent first, then persist task identities before any
                // resume. All selected jobs are queued while the app is active.
                try persistState()
                for file in incoming.files { try createTask(fileID: file.id, persist: false) }
                try persistState()
                let queued = Array(tasks.values)
                queued.forEach { $0.resume() }
                publish()
            } catch {
                stopOnQueue(kind: .failed, message: error.localizedDescription)
                throw error
            }
        }
    }

    func handle(_ command: LANTransferCommand) {
        stateQueue.async { [weak self] in
            guard let self, self.state?.offer.sessionID == command.sessionID else { return }
            switch command.kind {
            case .stop: self.stopOnQueue(kind: .cancelled, message: "手机已停止局域网传输。")
            case .cancel:
                if let id = command.fileID { self.cancelOnQueue(fileID: id) }
            }
        }
    }

    func stop(message: String = "已取消局域网传输。") {
        stateQueue.async { [weak self] in self?.stopOnQueue(kind: .cancelled, message: message) }
    }

    private func restoreOnQueue() {
        guard !didRestore else { return }
        didRestore = true
        do {
            try ensureDirectories()
            if let data = try? boundedData(outboxURL),
               let decoded = try? JSONDecoder().decode(LANBackgroundReceiptOutbox.self, from: data) {
                outbox = decoded
            }
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let data = try boundedData(snapshotURL)
                var restored = try JSONDecoder().decode(LANBackgroundTransferState.self, from: data)
                #if DEBUG
                let loopback = restored.allowsLoopbackForTesting
                #else
                let loopback = false
                #endif
                try restored.validateForRestoration(allowLoopback: loopback)
                // Receipts precede manifest updates on disk. A cancelled or
                // stored item must not restart after a crash between the writes.
                for event in outbox.events { restored.applyTerminalReceipt(event) }
                state = restored
                try persistState()
                // A crash can happen after writing a terminal phase but before
                // cleaning the batch. Reconstruct any missing durable receipts.
                for file in restored.offer.files {
                    guard let item = restored.items[file.id], !item.phase.isPending else { continue }
                    let kind: LANTransferEvent.Kind = item.phase == .stored ? .stored : (item.phase == .cancelled ? .cancelled : .failed)
                    let event = LANTransferEvent(sessionID: restored.offer.sessionID, fileID: file.id, kind: kind,
                                                 completedBytes: item.phase == .stored ? file.byteCount : item.receivedBytes,
                                                 totalBytes: file.byteCount, message: item.phase == .stored ? "歌曲已保存到手表" : "后台接收已结束")
                    if !outbox.contains(sessionID: event.sessionID, fileID: event.fileID) { outbox.insert(event) }
                }
                try persistOutbox()
                if restored.isFinished { state = nil; try? FileManager.default.removeItem(at: snapshotURL) }
            }
        } catch {
            // This file belongs only to this downloader. Do not touch the music
            // library when a bookkeeping file is malformed or inaccessible.
            state = nil
            try? FileManager.default.removeItem(at: snapshotURL)
            needsTerminalJournalRepair = FileManager.default.fileExists(atPath: snapshotURL.path)
        }
        deliveryBarrier.beginReconciliation()
        let session = makeSession()
        networkSession = session
        // A cached download does not appear in getAllTasks. Register its save
        // work before any background didFinishEvents callback can be delivered.
        if let state {
            for file in state.offer.files {
                if let item = state.items[file.id], item.phase == .validating, let name = item.stagingName {
                    startValidation(fileID: file.id, stagingName: name)
                }
            }
        }
        let restoredSessionID = state?.offer.sessionID
        session.getAllTasks { [weak self] allTasks in
            self?.stateQueue.async {
                guard let self else { return }
                self.reconcile(allTasks, restoredSessionID: restoredSessionID)
                self.deliveryBarrier.finishReconciliation()
                self.completeBackgroundEventsIfReady()
            }
        }
        for event in outbox.events { deliver(event) }
        publish()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = stateQueue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    private func reconcile(_ allTasks: [URLSessionTask], restoredSessionID: String?) {
        for task in allTasks {
            guard let identity = LANBackgroundTransferState.taskIdentity(task.taskDescription),
                  identity.sessionID == state?.offer.sessionID,
                  let item = state?.items[identity.fileID], item.phase.isPending,
                  item.phase != .validating,
                  item.taskIdentifier == task.taskIdentifier,
                  let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
            tasks[identity.fileID] = download
            missingRestoredFiles.remove(identity.fileID)
            if download.state == .suspended { download.resume() }
        }
        guard let state, state.offer.sessionID == restoredSessionID else { return }
        for file in state.offer.files {
            guard let item = self.state?.items[file.id], item.phase.isPending else { continue }
            if item.phase == .validating, let name = item.stagingName {
                startValidation(fileID: file.id, stagingName: name)
            } else if tasks[file.id] == nil, item.taskIdentifier != nil {
                // getAllTasks omits completed tasks whose delegate files have
                // not been delivered yet. Preserve their identity until drain.
                missingRestoredFiles.insert(file.id)
            }
        }
        if isForeground { resumeUnsubmittedIntents() }
        reconcileDrainedMissingTasks()
        cleanupUnreferencedFiles()
        publish()
    }

    private func resumeUnsubmittedIntents() {
        guard isForeground, let state else { return }
        for file in state.offer.files {
            guard let item = self.state?.items[file.id], item.phase.isPending,
                  item.phase != .validating, item.taskIdentifier == nil, tasks[file.id] == nil else { continue }
            do {
                try createTask(fileID: file.id, persist: true)
                tasks[file.id]?.resume()
            } catch { finish(fileID: file.id, kind: .failed, message: error.localizedDescription) }
        }
    }

    private func reconcileDrainedMissingTasks() {
        guard deliveryBarrier.eventsDrained else { return }
        let missing = missingRestoredFiles
        missingRestoredFiles = []
        for fileID in missing {
            guard let item = state?.items[fileID], item.phase.isPending,
                  item.phase != .validating, tasks[fileID] == nil else { continue }
            finish(fileID: fileID, kind: .failed, message: "系统下载任务已结束，请从手机重新发送。")
        }
    }

    private func createTask(fileID: String, persist: Bool) throws {
        guard let state, let file = state.file(for: fileID), let item = state.items[fileID],
              item.phase.isPending, item.phase != .validating,
              let session = networkSession else { throw receiverError("无法恢复局域网接收任务。") }
        guard state.canStartRequest(at: Date()) else { throw receiverError("局域网下载地址已过期，请从手机重新发送。") }
        let url = state.offer.baseURLs[item.addressIndex].appendingPathComponent("v1/files").appendingPathComponent(file.id)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + state.offer.token, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request)
        task.taskDescription = LANBackgroundTransferState.taskDescription(sessionID: state.offer.sessionID, fileID: fileID)
        task.countOfBytesClientExpectsToReceive = file.byteCount
        self.state?.items[fileID]?.taskIdentifier = task.taskIdentifier
        self.state?.items[fileID]?.phase = .downloading
        self.state?.items[fileID]?.receivedBytes = 0
        tasks[fileID] = task
        if persist {
            do { try persistState() }
            catch { task.cancel(); tasks.removeValue(forKey: fileID); throw error }
        }
    }

    private func binding(_ task: URLSessionTask) -> (LANTransferFile, LANBackgroundTransferState.Item)? {
        guard let state, let identity = LANBackgroundTransferState.taskIdentity(task.taskDescription),
              identity.sessionID == state.offer.sessionID, let file = state.file(for: identity.fileID),
              let item = state.items[file.id], item.phase.isPending, item.phase != .validating,
              item.taskIdentifier == task.taskIdentifier else { return nil }
        return (file, item)
    }

    private func cancelOnQueue(fileID: String) {
        guard state?.items[fileID]?.phase.isPending == true else { return }
        if permissions[fileID]?.cancel() == false {
            finish(fileID: fileID, kind: .stored, message: "歌曲已保存到手表")
        } else {
            tasks[fileID]?.cancel()
            finish(fileID: fileID, kind: .cancelled, message: "已取消")
        }
    }

    private func stopOnQueue(kind: LANTransferEvent.Kind, message: String) {
        guard let state else { return }
        for file in state.offer.files where self.state?.items[file.id]?.phase.isPending == true {
            if permissions[file.id]?.cancel() == false {
                finish(fileID: file.id, kind: .stored, message: "歌曲已保存到手表")
            } else {
                tasks[file.id]?.cancel()
                finish(fileID: file.id, kind: kind, message: message)
            }
        }
    }

    private func finish(fileID: String, kind: LANTransferEvent.Kind, message: String?) {
        guard let state, let file = state.file(for: fileID), let item = state.items[fileID], item.phase.isPending else { return }
        let stagingName = item.stagingName
        let event = LANTransferEvent(sessionID: state.offer.sessionID, fileID: fileID, kind: kind,
                                     completedBytes: kind == .stored ? file.byteCount : item.receivedBytes,
                                     totalBytes: file.byteCount, message: message)
        // The receipt is persisted before clearing either the cached download or
        // the batch state. Replaying it is safe because the phone binds IDs.
        guard self.state?.recordTerminal(fileID: fileID, kind: kind) == true else { return }
        outbox.insert(event)
        let outboxSaved = (try? persistOutbox()) != nil
        let stateSaved = (try? persistState()) != nil
        if !stateSaved { needsTerminalJournalRepair = true }
        tasks.removeValue(forKey: fileID)
        missingRestoredFiles.remove(fileID)
        permissions.removeValue(forKey: fileID)
        if outboxSaved && stateSaved, let name = stagingName { try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(name)) }
        deliver(event)
        if self.state?.isFinished == true {
            self.state = nil
            if outboxSaved && stateSaved { try? FileManager.default.removeItem(at: snapshotURL) }
        }
        publish()
    }

    private func startValidation(fileID: String, stagingName: String) {
        guard let state, let file = state.file(for: fileID), state.items[fileID]?.phase == .validating else { return }
        let key = receiptKey(sessionID: state.offer.sessionID, fileID: fileID)
        guard deliveryBarrier.beginValidation(key) else { return }
        let permission = permissions[fileID] ?? LANStoragePermission()
        permissions[fileID] = permission
        let temporary = stagingRoot.appendingPathComponent(stagingName)
        let sessionID = state.offer.sessionID
        validationQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.storeFile(temporary, file, permission) }
            self.stateQueue.async {
                self.deliveryBarrier.finishValidation(key)
                guard self.state?.offer.sessionID == sessionID,
                      self.state?.items[fileID]?.phase == .validating,
                      self.permissions[fileID] === permission else {
                    try? FileManager.default.removeItem(at: temporary)
                    self.completeBackgroundEventsIfReady()
                    return
                }
                switch result {
                case .success: self.finish(fileID: fileID, kind: .stored, message: "歌曲已保存到手表")
                case .failure(let error): self.finish(fileID: fileID, kind: error is CancellationError ? .cancelled : .failed, message: error.localizedDescription)
                }
                self.completeBackgroundEventsIfReady()
            }
        }
    }

    private func publish() {
        let status: LANReceptionStatus?
        if let state, let file = state.offer.files.first(where: { state.items[$0.id]?.phase.isPending == true }), let item = state.items[file.id] {
            let completed = state.items.values.filter { !$0.phase.isPending }.count
            status = LANReceptionStatus(fileName: file.fileName, completedBytes: item.receivedBytes,
                                        totalBytes: file.byteCount, fileIndex: completed + 1,
                                        fileCount: state.offer.files.count, isSaving: item.phase == .validating)
        } else { status = nil }
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stateQueue.sync(execute: { self.generation == currentGeneration }) else { return }
            self.onUpdate?(status)
        }
    }

    private func deliver(_ event: LANTransferEvent) {
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if event.kind == .progress, !self.stateQueue.sync(execute: { self.generation == currentGeneration }) { return }
            self.onEvent?(event)
        }
    }

    private func emitProgress(_ file: LANTransferFile, message: String? = nil) {
        guard let state, let item = state.items[file.id] else { return }
        deliver(LANTransferEvent(sessionID: state.offer.sessionID, fileID: file.id, kind: .progress,
                                 completedBytes: item.receivedBytes, totalBytes: file.byteCount, message: message))
    }

    private func completeBackgroundEventsIfReady() {
        guard deliveryBarrier.canComplete, !backgroundCompletions.isEmpty else { return }
        let completions = backgroundCompletions
        backgroundCompletions = []
        DispatchQueue.main.async { completions.forEach { $0() } }
    }

    private func ensureDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = root
        try? directory.setResourceValues(values)
        protect(root)
        protect(stagingRoot)
    }

    private func protect(_ url: URL) {
        #if os(iOS) || os(watchOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private func boundedData(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_097_152 else { throw receiverError("后台接收记录过大。") }
        return try Data(contentsOf: url)
    }

    private func persistState() throws {
        guard let state else { return }
        try JSONEncoder().encode(state).write(to: snapshotURL, options: .atomic)
        protect(snapshotURL)
        needsTerminalJournalRepair = false
        lastSnapshotTime = ProcessInfo.processInfo.systemUptime
    }

    private func persistOutbox() throws {
        try ensureDirectories()
        try JSONEncoder().encode(outbox).write(to: outboxURL, options: .atomic)
        protect(outboxURL)
    }

    private func cleanupUnreferencedFiles() {
        let needed = Set(state?.items.values.compactMap(\.stagingName) ?? [])
        guard let files = try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) else { return }
        for url in files where !needed.contains(url.lastPathComponent) && LANBackgroundTransferState.isStagingName(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func receiptKey(sessionID: String, fileID: String) -> String { sessionID + "/" + fileID }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard session === networkSession, let (file, _) = binding(downloadTask) else { return }
        if totalBytesWritten > file.byteCount {
            downloadTask.cancel()
            finish(fileID: file.id, kind: .failed, message: "接收大小超出歌曲清单，已停止。")
            return
        }
        guard state?.recordProgress(fileID: file.id, bytes: max(0, totalBytesWritten)) == true else { return }
        deliveryBarrier.beginDelivery()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSnapshotTime >= 1 { try? persistState() }
        if now - (lastProgressTime[file.id] ?? 0) >= 1 || totalBytesWritten == file.byteCount {
            lastProgressTime[file.id] = now
            emitProgress(file)
        }
        publish()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard session === networkSession, let (file, _) = binding(downloadTask), let state else { return }
        deliveryBarrier.beginDelivery()
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            failOrTryAnotherAddress(fileID: file.id, error: receiverError("局域网下载失败（HTTP \(status)）。"), mayRetry: status >= 500 || status == 0)
            return
        }
        // Background URL sessions always follow redirects. Check the actual
        // response endpoint before treating any downloaded bytes as trusted.
        guard let finalURL = response.url, state.offer.baseURLs.contains(where: {
            let expected = $0.appendingPathComponent("v1/files").appendingPathComponent(file.id)
            return finalURL.scheme == expected.scheme && finalURL.host == expected.host &&
                finalURL.port == expected.port && finalURL.path == expected.path &&
                finalURL.query == nil && finalURL.fragment == nil && finalURL.user == nil && finalURL.password == nil
        }) else { finish(fileID: file.id, kind: .failed, message: "下载地址发生变化，已拒绝保存。"); return }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) == file.byteCount else { throw receiverError("接收的歌曲大小不符，请重新发送。") }
            let name = UUID().uuidString + ".download"
            let temporary = stagingRoot.appendingPathComponent(name)
            try FileManager.default.moveItem(at: location, to: temporary)
            protect(temporary)
            guard self.state?.recordDownloaded(fileID: file.id, stagingName: name) == true else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            tasks.removeValue(forKey: file.id)
            try persistState()
            emitProgress(file, message: "正在校验并保存")
            publish()
            startValidation(fileID: file.id, stagingName: name)
        } catch { finish(fileID: file.id, kind: .failed, message: error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === networkSession, let (file, _) = binding(task) else { return }
        deliveryBarrier.beginDelivery()
        tasks.removeValue(forKey: file.id)
        if let error {
            failOrTryAnotherAddress(fileID: file.id, error: error, mayRetry: (error as NSError).code != NSURLErrorCancelled)
        } else { finish(fileID: file.id, kind: .failed, message: "下载没有返回可保存的歌曲文件。") }
    }

    private func failOrTryAnotherAddress(fileID: String, error: Error, mayRetry: Bool) {
        guard let state, let item = state.items[fileID] else { return }
        tasks.removeValue(forKey: fileID)
        if mayRetry, item.receivedBytes == 0, item.addressIndex + 1 < state.offer.baseURLs.count, state.offer.expiresAt > Date() {
            self.state?.items[fileID]?.addressIndex += 1
            do { try createTask(fileID: fileID, persist: true); tasks[fileID]?.resume() }
            catch { finish(fileID: fileID, kind: .failed, message: error.localizedDescription) }
        } else { finish(fileID: fileID, kind: .failed, message: error.localizedDescription) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard session === networkSession else { return }
        deliveryBarrier.didFinishEvents()
        reconcileDrainedMissingTasks()
        completeBackgroundEventsIfReady()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Honored for in-process sessions only; background final-URL validation
        // above remains necessary because the daemon can follow redirects.
        completionHandler(nil)
    }

    private func receiverError(_ message: String) -> NSError {
        NSError(domain: "LANDownloadReceiver", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
