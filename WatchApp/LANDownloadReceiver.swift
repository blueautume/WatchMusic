import Foundation

struct LANReceptionStatus {
    let fileName: String
    let completedBytes: Int64
    let totalBytes: Int64
    let fileIndex: Int
    let fileCount: Int
    let isSaving: Bool
    var isPaused = false
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
    private var isReconcilingTasks = false
    private var pendingControls: [(LANTransferCommand, (([LANTransferEvent]) -> Void)?)] = []
    private var activeFileID: String?
    private var validatingFileID: String?
    private var drainingTaskIDs = Set<Int>()
    private var schedulingSuspensionCount = 0
    private var isAdvancingQueue = false
    #if DEBUG
    private var debugControlStates: [[String: Any]] = []
    #endif

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
            if value { self.advanceQueue() }
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
            activeFileID = nil
            deliveryBarrier.beginDelivery()
            do {
                // Persist the whole queue, but create a native download only
                // when its predecessor has finished saving.
                try persistState()
                advanceQueue()
                publish()
            } catch {
                stopOnQueue(kind: .failed, message: error.localizedDescription)
                throw error
            }
        }
    }

    func handle(_ command: LANTransferCommand, completion: (([LANTransferEvent]) -> Void)? = nil) {
        stateQueue.async { [weak self] in
            self?.handleOnQueue(command, completion: completion)
        }
    }

    private func handleOnQueue(_ command: LANTransferCommand, completion: (([LANTransferEvent]) -> Void)?) {
            if isReconcilingTasks { pendingControls.append((command, completion)); return }
            guard command.kind == .status || state?.offer.sessionID == command.sessionID else {
                if let completion { DispatchQueue.main.async { completion([]) } }
                return
            }
            // Apply a batch atomically before advancing, so pausing/cancelling
            // every item never starts another item between individual controls.
            schedulingSuspensionCount += 1
            defer { schedulingSuspensionCount -= 1; advanceQueue() }
            var events: [LANTransferEvent] = []
            switch command.kind {
            case .stop: self.stopOnQueue(kind: .cancelled, message: "手机已停止局域网传输。")
            case .cancel:
                for id in command.fileIDs ?? command.fileID.map({ [$0] }) ?? [] { self.cancelOnQueue(fileID: id) }
            case .pause, .resume:
                let ids = command.fileIDs ?? command.fileID.map({ [$0] }) ?? Array(self.state?.pendingFileIDs ?? [])
                for id in Set(ids) {
                    if let event = self.controlOnQueue(fileID: id, paused: command.kind == .pause,
                                                       revision: command.controlRevision ?? 0) { events.append(event) }
                }
            case .status:
                let ids = command.fileIDs ?? command.fileID.map({ [$0] }) ?? Array(self.state?.pendingFileIDs ?? [])
                events = ids.compactMap { self.controlEvent(fileID: $0) }
            }
            if let completion { DispatchQueue.main.async { completion(events) } }
    }

    private func controlOnQueue(fileID: String, paused: Bool, revision: Int64) -> LANTransferEvent? {
        guard let before = state?.items[fileID], let file = state?.file(for: fileID) else { return nil }
        if state?.setPaused(fileID: fileID, paused: paused, revision: revision) == true {
            do { try persistState() }
            catch { state?.items[fileID] = before; return controlEvent(fileID: fileID, message: "无法保存暂停状态，请重试。") }
            if paused {
                if tasks[fileID]?.state == .running { tasks[fileID]?.suspend() }
            }
        }
        guard let event = controlEvent(fileID: fileID) else { return nil }
        #if DEBUG
        recordControlProbe(fileID: fileID)
        if paused, state?.items[fileID]?.phase == .paused {
            for delay in [1.0, 2.0] {
                stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.state?.items[fileID]?.phase == .paused,
                          self.state?.items[fileID]?.controlRevision == revision else { return }
                    self.recordControlProbe(fileID: fileID)
                }
            }
        }
        #endif
        lastProgressTime[file.id] = 0
        deliver(event)
        publish()
        return event
    }

    #if DEBUG
    /// Native-task observation for the real HTTP probe, never normal launches.
    private func recordControlProbe(fileID: String) {
        guard ProcessInfo.processInfo.arguments.contains("-lan-offer-file"), let item = state?.items[fileID] else { return }
        let native: String
        if let task = tasks[fileID] {
            switch task.state {
            case .running: native = "running"
            case .suspended: native = "suspended"
            case .canceling: native = "canceling"
            case .completed: native = "completed"
            @unknown default: native = "unknown"
            }
        } else { native = item.stagingName == nil ? "notCreated" : "cached" }
        debugControlStates.append(["fileID": fileID, "phase": item.phase.rawValue,
                                   "nativeState": native, "revision": item.controlRevision ?? 0,
                                   "receivedBytes": item.receivedBytes,
                                   "nativeBytes": tasks[fileID]?.countOfBytesReceived ?? item.receivedBytes])
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("lan-test-control-states.json")
        if let data = try? JSONSerialization.data(withJSONObject: debugControlStates) { try? data.write(to: path, options: .atomic) }
    }
    #endif

    private func controlEvent(fileID: String, message: String? = nil) -> LANTransferEvent? {
        guard let state, let file = state.file(for: fileID), let item = state.items[fileID] else { return nil }
        let kind: LANTransferEvent.Kind
        switch item.phase {
        case .paused: kind = .paused
        case .queued, .downloading: kind = .resumed
        case .validating: kind = .resumed
        case .stored: kind = .stored
        case .failed: kind = .failed
        case .cancelled: kind = .cancelled
        }
        return LANTransferEvent(sessionID: state.offer.sessionID, fileID: fileID, kind: kind,
                                completedBytes: item.receivedBytes, totalBytes: file.byteCount,
                                message: message ?? (item.phase == .paused ? "已暂停" : "继续传输"),
                                controlRevision: item.controlRevision)
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
        isReconcilingTasks = true
        let session = makeSession()
        networkSession = session
        let restoredSessionID = state?.offer.sessionID
        session.getAllTasks { [weak self] allTasks in
            self?.stateQueue.async {
                guard let self else { return }
                self.reconcile(allTasks, restoredSessionID: restoredSessionID)
                self.deliveryBarrier.finishReconciliation()
                self.isReconcilingTasks = false
                let controls = self.pendingControls
                self.pendingControls = []
                self.schedulingSuspensionCount += 1
                for (command, completion) in controls { self.handleOnQueue(command, completion: completion) }
                self.schedulingSuspensionCount -= 1
                self.advanceQueue()
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
                  let download = task as? URLSessionDownloadTask else {
                if task.state != .completed { drainingTaskIDs.insert(task.taskIdentifier); task.cancel() }
                continue
            }
            tasks[identity.fileID] = download
            missingRestoredFiles.remove(identity.fileID)
            // Old builds may have submitted the entire batch. Reclaim every
            // running task before choosing exactly one through the scheduler.
            if download.state == .running { download.suspend() }
        }
        guard let state, state.offer.sessionID == restoredSessionID else { return }
        for file in state.offer.files {
            guard let item = self.state?.items[file.id], item.phase.isPending else { continue }
            if item.phase != .validating, tasks[file.id] == nil, item.taskIdentifier != nil {
                // getAllTasks omits completed tasks whose delegate files have
                // not been delivered yet. Preserve their identity until drain.
                missingRestoredFiles.insert(file.id)
            }
        }
        reconcileDrainedMissingTasks()
        cleanupUnreferencedFiles()
        publish()
    }

    /// The only entry point that starts network or validation work. Queue
    /// advancement also runs during a background delivery, without requiring
    /// the screen to be active.
    private func advanceQueue() {
        guard !isReconcilingTasks, schedulingSuspensionCount == 0, !isAdvancingQueue else { return }
        isAdvancingQueue = true
        defer { isAdvancingQueue = false }
        while let state {
            let next = state.nextRunnableFileID(keeping: activeFileID)
            var changed = false
            for (fileID, task) in tasks where fileID != next {
                if task.state == .running { task.suspend() }
                if self.state?.items[fileID]?.phase == .downloading {
                    self.state?.items[fileID]?.phase = .queued
                    changed = true
                }
            }
            if changed { try? persistState() }
            guard drainingTaskIDs.isEmpty, validatingFileID == nil else { return }
            activeFileID = next
            guard let fileID = next, let item = self.state?.items[fileID] else { publish(); return }
            if let name = item.stagingName {
                startValidation(fileID: fileID, stagingName: name)
                publish()
                return
            }
            guard !missingRestoredFiles.contains(fileID) else { return }
            do {
                if tasks[fileID] == nil { try createTask(fileID: fileID, persist: true) }
                if let task = tasks[fileID], task.state == .suspended {
                    guard self.state?.canStartRequest(at: Date()) == true else {
                        throw receiverError("局域网下载地址已过期，请从手机重新发送。")
                    }
                    self.state?.items[fileID]?.phase = .downloading
                    try persistState()
                    task.resume()
                }
                publish()
                return
            } catch {
                finish(fileID: fileID, kind: .failed, message: error.localizedDescription)
            }
        }
        activeFileID = nil
    }

    private func reconcileDrainedMissingTasks() {
        guard deliveryBarrier.eventsDrained else { return }
        let missing = missingRestoredFiles
        missingRestoredFiles = []
        for fileID in missing {
            guard let item = state?.items[fileID], item.phase.isPending,
                  item.phase != .validating, item.stagingName == nil, tasks[fileID] == nil else { continue }
            if item.phase == .paused {
                state?.items[fileID]?.taskIdentifier = nil
                try? persistState()
                continue
            }
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
        if item.phase != .paused { self.state?.items[fileID]?.phase = .downloading }
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
        schedulingSuspensionCount += 1
        defer { schedulingSuspensionCount -= 1; advanceQueue() }
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
        if let task = tasks.removeValue(forKey: fileID), task.state != .completed {
            drainingTaskIDs.insert(task.taskIdentifier)
            task.cancel()
        }
        missingRestoredFiles.remove(fileID)
        permissions.removeValue(forKey: fileID)
        if outboxSaved && stateSaved, let name = stagingName { try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(name)) }
        deliver(event)
        if self.state?.isFinished == true {
            self.state = nil
            if outboxSaved && stateSaved { try? FileManager.default.removeItem(at: snapshotURL) }
        }
        publish()
        advanceQueue()
    }

    private func startValidation(fileID: String, stagingName: String) {
        guard let state, let file = state.file(for: fileID), state.items[fileID]?.phase == .validating else { return }
        let key = receiptKey(sessionID: state.offer.sessionID, fileID: fileID)
        guard deliveryBarrier.beginValidation(key) else { return }
        validatingFileID = fileID
        let permission = permissions[fileID] ?? LANStoragePermission()
        permissions[fileID] = permission
        let temporary = stagingRoot.appendingPathComponent(stagingName)
        let sessionID = state.offer.sessionID
        validationQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.storeFile(temporary, file, permission) }
            self.stateQueue.async {
                self.deliveryBarrier.finishValidation(key)
                self.validatingFileID = nil
                guard self.state?.offer.sessionID == sessionID,
                      self.state?.items[fileID]?.phase == .validating,
                      self.permissions[fileID] === permission else {
                    try? FileManager.default.removeItem(at: temporary)
                    self.advanceQueue()
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
        if let state, let file = state.nextRunnableFileID(keeping: activeFileID).flatMap({ state.file(for: $0) }) ?? state.offer.files.first(where: { state.items[$0.id]?.phase == .paused }), let item = state.items[file.id] {
            let completed = state.items.values.filter { !$0.phase.isPending }.count
            status = LANReceptionStatus(fileName: file.fileName, completedBytes: item.receivedBytes,
                                        totalBytes: file.byteCount, fileIndex: completed + 1,
                                        fileCount: state.offer.files.count, isSaving: item.phase == .validating,
                                        isPaused: item.phase == .paused)
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
            if !event.kind.isTerminal, !self.stateQueue.sync(execute: { self.generation == currentGeneration }) { return }
            self.onEvent?(event)
        }
    }

    private func emitProgress(_ file: LANTransferFile, message: String? = nil) {
        guard let state, let item = state.items[file.id] else { return }
        deliver(LANTransferEvent(sessionID: state.offer.sessionID, fileID: file.id, kind: item.phase == .paused ? .paused : .progress,
                                 completedBytes: item.receivedBytes, totalBytes: file.byteCount, message: message,
                                 controlRevision: item.controlRevision))
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
        guard let response = downloadTask.response as? HTTPURLResponse,
              LANTransferValidation.isValidDownloadResponse(statusCode: response.statusCode,
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"), expectedByteCount: file.byteCount) else {
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
            emitProgress(file, message: self.state?.items[file.id]?.phase == .paused ? "已暂停" : "正在校验并保存")
            publish()
            advanceQueue()
        } catch { finish(fileID: file.id, kind: .failed, message: error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === networkSession else { return }
        if drainingTaskIDs.remove(task.taskIdentifier) != nil {
            advanceQueue()
            completeBackgroundEventsIfReady()
            return
        }
        guard let (file, _) = binding(task) else { return }
        deliveryBarrier.beginDelivery()
        tasks.removeValue(forKey: file.id)
        if state?.items[file.id]?.phase == .paused, error != nil {
            state?.items[file.id]?.taskIdentifier = nil
            missingRestoredFiles.remove(file.id)
            try? persistState()
            publish()
            advanceQueue()
            return
        }
        if let error {
            failOrTryAnotherAddress(fileID: file.id, error: error, mayRetry: (error as NSError).code != NSURLErrorCancelled)
        } else { finish(fileID: file.id, kind: .failed, message: "下载没有返回可保存的歌曲文件。") }
    }

    private func failOrTryAnotherAddress(fileID: String, error: Error, mayRetry: Bool) {
        guard let state, let item = state.items[fileID] else { return }
        if let task = tasks.removeValue(forKey: fileID), task.state != .completed {
            drainingTaskIDs.insert(task.taskIdentifier)
            task.cancel()
        }
        self.state?.items[fileID]?.taskIdentifier = nil
        if mayRetry, item.receivedBytes == 0, item.addressIndex + 1 < state.offer.baseURLs.count, state.offer.expiresAt > Date() {
            self.state?.items[fileID]?.addressIndex += 1
            do { try persistState(); advanceQueue() }
            catch { finish(fileID: fileID, kind: .failed, message: error.localizedDescription) }
        } else { finish(fileID: fileID, kind: .failed, message: error.localizedDescription) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard session === networkSession else { return }
        deliveryBarrier.didFinishEvents()
        reconcileDrainedMissingTasks()
        advanceQueue()
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
