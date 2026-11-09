import Foundation
import OSLog

enum LANReceiverAvailability {
    case active, inactive, background
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

/// URLSession owns every accepted download. The app only journals controls,
/// validates completed files, and delivers durable receipts when it can execute.
final class LANDownloadReceiver: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private static let logger = Logger(subsystem: "com.lihao.WatchMusic.watchkitapp", category: "LANDownload")
    static var backgroundSessionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.lihao.WatchMusic") + ".lan-download.v2"
    }

    var onUpdate: ((LANReceptionStatus?) -> Void)?
    var onEvent: ((LANTransferEvent) -> Void)?
    private let stateQueue = DispatchQueue(label: "com.lihao.WatchMusic.lan-download")
    private let validationQueue = DispatchQueue(label: "com.lihao.WatchMusic.lan-validation", qos: .utility)
    private let storeFile: (URL, LANTransferFile, LANStoragePermission) throws -> Void
    private let root: URL
    private let stagingRoot: URL
    private let snapshotURL: URL
    private let outboxURL: URL
    private var networkSession: URLSession?
    private var state: LANBackgroundTransferState?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var permissions: [String: LANStoragePermission] = [:]
    private var outbox = LANBackgroundReceiptOutbox()
    // Keep the current batch's outcomes after handing receipts to WCSession,
    // so a reconnect can reconcile without reopening a completed HTTP source.
    private var terminalResults: [String: LANTransferEvent] = [:]
    private var needsTerminalJournalRepair = false
    private var lastProgressTime: [String: TimeInterval] = [:]
    private var lastUIProgressTime: TimeInterval = 0
    private var lastSnapshotTime: TimeInterval = 0
    // Main-queue callbacks check this token without waiting for state or disk I/O.
    private let generationLock = NSLock()
    private var generation = UUID()
    private var didRestore = false
    private var backgroundCompletions: [() -> Void] = []
    private var availability = LANReceiverAvailability.background
    private var validatingFileID: String?
    private var reconcilingTasks = false
    private var backgroundEventsFinished = false
    private var backgroundExecutionExpired = false
    private var interruptedValidations = Set<ObjectIdentifier>()
    private var schedulingSuspensionCount = 0
    private var isAdvancingQueue = false
    #if DEBUG
    var onTaskReconciliationForProbe: ((Int) -> Void)?
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

    func setAvailability(_ value: LANReceiverAvailability) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.restoreOnQueue()
            guard self.availability != value else { return }
            self.availability = value
            if value == .active {
                self.backgroundExecutionExpired = false
                self.signalSourceRecovery()
            }
            // Display and scene changes never cancel system-owned downloads.
            self.advanceQueue()
            if value == .active { self.logNativeTaskSnapshot() }
        }
    }

    /// Observe once when the person returns to the app. This read-only query
    /// never reconciles or controls tasks, and creates no monitoring timer.
    private func logNativeTaskSnapshot() {
        guard let session = networkSession else { return }
        let requestedAt = Date().timeIntervalSince1970
        session.getAllTasks { [weak self, weak session] nativeTasks in
            guard let self, let session else { return }
            self.stateQueue.async { [weak self, weak session] in
                guard let self, let session, session === self.networkSession else { return }
                let identifier = session.configuration.identifier ?? "none"
                let observedAt = Date().timeIntervalSince1970
                Self.logger.notice("Native task snapshot: session \(identifier, privacy: .public), count \(nativeTasks.count), requestedAt \(requestedAt), observedAt \(observedAt)")
                for task in nativeTasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
                    let state = Self.nativeTaskStateName(task.state)
                    Self.logger.notice("Native task snapshot: task \(task.taskIdentifier), state \(state, privacy: .public), received \(task.countOfBytesReceived), expected \(task.countOfBytesExpectedToReceive)")
                }
            }
        }
    }

    private static func nativeTaskStateName(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running: "running"
        case .suspended: "suspended"
        case .canceling: "canceling"
        case .completed: "completed"
        @unknown default: "unknown"
        }
    }

    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        stateQueue.async { [weak self] in
            guard let self, identifier == Self.backgroundSessionIdentifier else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            self.restoreOnQueue()
            self.backgroundExecutionExpired = false
            self.backgroundCompletions.append(completion)
            self.advanceQueue()
            self.completeBackgroundEventsIfReady()
        }
    }

    func expireBackgroundEvents(identifier: String) {
        stateQueue.async { [weak self] in
            guard let self, identifier == Self.backgroundSessionIdentifier else { return }
            if self.availability != .active {
                self.backgroundExecutionExpired = true
                for permission in self.permissions.values where permission.cancel() {
                    self.interruptedValidations.insert(ObjectIdentifier(permission))
                }
            }
            // Revoke permission before releasing the WatchKit execution lease.
            // The cache remains journaled and can be verified on the next wake.
            self.completeBackgroundCompletions()
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
            guard availability == .active else { throw receiverError("请保持手表 App 打开后再传输。") }
            guard state == nil else { throw receiverError("正在接收另一批歌曲，请完成或取消后重试。") }
            guard outbox.count + incoming.files.count <= 2_000 else { throw receiverError("请先连接手机同步接收结果后重试。") }
            try ensureDirectories()
            generationLock.withLock { generation = UUID() }
            state = LANBackgroundTransferState(offer: incoming, allowsLoopbackForTesting: allowLoopbackForTesting)
            terminalResults.removeAll(keepingCapacity: true)
            tasks = [:]
            permissions = [:]
            lastProgressTime = [:]
            lastUIProgressTime = 0
            do {
                // Submit the batch while active; no per-file app wake is needed
                // for the daemon to start the remaining downloads.
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
                                                   revision: command.controlRevision ?? 0,
                                                   automatic: command.automaticPause == true) { events.append(event) }
            }
        case .status:
            let matchingState = state?.offer.sessionID == command.sessionID
            let ids = command.fileIDs ?? command.fileID.map({ [$0] }) ??
                (matchingState ? state?.offer.files.map(\.id) ?? [] : terminalResults.values.filter {
                    $0.sessionID == command.sessionID
                }.map(\.fileID))
            events = ids.compactMap { id in
                if matchingState, let event = self.controlEvent(fileID: id) { return event }
                guard let event = self.terminalResults[id], event.sessionID == command.sessionID else { return nil }
                return event
            }
        }
        if let completion { DispatchQueue.main.async { completion(events) } }
    }

    private func controlOnQueue(fileID: String, paused: Bool, revision: Int64, automatic: Bool) -> LANTransferEvent? {
        guard let before = state?.items[fileID], let file = state?.file(for: fileID) else { return nil }
        if automatic {
            if paused { pauseForUnavailableSource(fileIDs: [fileID], message: "等待手机 App 打开") }
            else { signalSourceRecovery(fileIDs: [fileID]) }
            return controlEvent(fileID: fileID)
        }
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

    private func controlEvent(fileID: String, message: String? = nil, automatic: Bool? = nil) -> LANTransferEvent? {
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
                                controlRevision: item.controlRevision,
                                automaticPause: automatic ?? (item.lifecyclePaused == true ? true : nil))
    }

    private func pauseForUnavailableSource(fileIDs: Set<String>? = nil, message: String) {
        guard let state else { return }
        schedulingSuspensionCount += 1
        defer { schedulingSuspensionCount -= 1 }
        for file in state.offer.files where fileIDs == nil || fileIDs!.contains(file.id) {
            guard let phase = self.state?.items[file.id]?.phase, phase.isPending, phase != .validating else { continue }
            let wasAutomaticallyPaused = self.state?.items[file.id]?.lifecyclePaused == true
            let changed = self.state?.setLifecyclePaused(fileID: file.id, paused: true) == true
            if let task = tasks.removeValue(forKey: file.id), task.state != .completed {
                task.cancel()
            }
            self.state?.items[file.id]?.taskIdentifier = nil
            if self.state?.items[file.id]?.stagingName == nil { self.state?.items[file.id]?.receivedBytes = 0 }
            if changed && !wasAutomaticallyPaused, let event = controlEvent(fileID: file.id, message: message, automatic: true) { deliver(event) }
        }
        try? persistState()
        publish()
    }

    private func signalSourceRecovery(fileIDs: Set<String>? = nil) {
        guard availability == .active, let state else { return }
        for file in state.offer.files where fileIDs == nil || fileIDs!.contains(file.id) {
            guard let item = self.state?.items[file.id], item.lifecyclePaused == true else { continue }
            // The phone may already have closed this URL. Signal readiness,
            // but wait for its fresh offer instead of retrying stale requests.
            deliver(LANTransferEvent(sessionID: state.offer.sessionID, fileID: file.id, kind: .resumed,
                completedBytes: item.receivedBytes, totalBytes: file.byteCount,
                message: "手表 App 已打开，等待手机重新开始", controlRevision: item.controlRevision, automaticPause: true))
        }
        publish()
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
        cleanupUnreferencedFiles()
        reconcilingTasks = true
        networkSession = makeSession()
        networkSession?.getAllTasks { [weak self] allTasks in
            self?.stateQueue.async { [weak self] in self?.reconcile(allTasks) }
        }
        for event in outbox.events {
            terminalResults[event.fileID] = event
            deliver(event)
        }
        publish()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
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

    /// Reattach tasks before creating anything. Persisted task IDs and immutable
    /// session/file identities prevent a stale or duplicate task from taking over.
    private func reconcile(_ nativeTasks: [URLSessionTask]) {
        var restoredCount = 0
        for nativeTask in nativeTasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
            guard let task = nativeTask as? URLSessionDownloadTask,
                  let state, let identity = LANBackgroundTransferState.taskIdentity(task.taskDescription),
                  identity.sessionID == state.offer.sessionID,
                  let item = state.items[identity.fileID], item.phase.isPending, item.stagingName == nil,
                  let originalURL = task.originalRequest?.url,
                  isAuthorizedURL(originalURL, fileID: identity.fileID),
                  item.taskIdentifier == nil || item.taskIdentifier == task.taskIdentifier,
                  tasks[identity.fileID] == nil || tasks[identity.fileID]?.taskIdentifier == task.taskIdentifier else {
                nativeTask.cancel()
                continue
            }
            tasks[identity.fileID] = task
            self.state?.items[identity.fileID]?.taskIdentifier = task.taskIdentifier
            if item.phase == .paused, task.state == .running { task.suspend() }
            restoredCount += 1
        }
        for id in state?.pendingFileIDs ?? [] where tasks[id] == nil {
            state?.items[id]?.taskIdentifier = nil
            if state?.items[id]?.stagingName == nil {
                state?.items[id]?.receivedBytes = 0
                if state?.items[id]?.phase == .downloading { state?.items[id]?.phase = .queued }
            }
        }
        try? persistState()
        reconcilingTasks = false
        Self.logger.notice("Reattached \(restoredCount) background download tasks")
        #if DEBUG
        DispatchQueue.main.async { [weak self] in self?.onTaskReconciliationForProbe?(restoredCount) }
        #endif
        advanceQueue()
        completeBackgroundEventsIfReady()
    }

    /// Queue all runnable files with the system; validation alone is serialized.
    /// A sleeping or suspended app is never needed to start the next download.
    private func advanceQueue() {
        guard !reconcilingTasks, schedulingSuspensionCount == 0, !isAdvancingQueue else { return }
        isAdvancingQueue = true
        defer { isAdvancingQueue = false }
        guard let state else { return }
        var created: [String] = []
        for file in state.offer.files {
            guard let item = self.state?.items[file.id], item.phase == .queued || item.phase == .downloading,
                  item.stagingName == nil, tasks[file.id] == nil else { continue }
            do {
                try createTask(fileID: file.id)
                created.append(file.id)
            } catch { finish(fileID: file.id, kind: .failed, message: error.localizedDescription) }
        }
        if !created.isEmpty {
            do { try persistState() }
            catch {
                for id in created { finish(fileID: id, kind: .failed, message: error.localizedDescription) }
            }
        }
        for (id, task) in tasks {
            guard let phase = self.state?.items[id]?.phase else { continue }
            if phase == .paused {
                if task.state == .running { task.suspend() }
            } else if phase == .queued || phase == .downloading, task.state == .suspended {
                task.resume()
            }
        }
        if !backgroundExecutionExpired, validatingFileID == nil,
           let file = self.state?.offer.files.first(where: { self.state?.items[$0.id]?.phase == .validating }),
           let name = self.state?.items[file.id]?.stagingName {
            startValidation(fileID: file.id, stagingName: name)
        }
        publish()
    }

    private func createTask(fileID: String) throws {
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
        self.state?.items[fileID]?.phase = .queued
        self.state?.items[fileID]?.receivedBytes = 0
        tasks[fileID] = task
    }

    private func binding(_ task: URLSessionTask) -> (LANTransferFile, LANBackgroundTransferState.Item)? {
        guard let state, let identity = LANBackgroundTransferState.taskIdentity(task.taskDescription),
              identity.sessionID == state.offer.sessionID, let file = state.file(for: identity.fileID),
              let item = state.items[file.id], item.phase.isPending, item.phase != .validating,
              item.taskIdentifier == task.taskIdentifier else { return nil }
        // Delegate events can arrive before getAllTasks finishes on relaunch.
        // The persisted identity is sufficient to accept that exact native task.
        if let downloadTask = task as? URLSessionDownloadTask { tasks[file.id] = downloadTask }
        return (file, item)
    }

    private func isAuthorizedURL(_ url: URL, fileID: String) -> Bool {
        state?.offer.baseURLs.contains(where: {
            let expected = $0.appendingPathComponent("v1/files").appendingPathComponent(fileID)
            return url.scheme == expected.scheme && url.host == expected.host &&
                url.port == expected.port && url.path == expected.path &&
                url.query == nil && url.fragment == nil && url.user == nil && url.password == nil
        }) == true
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
        terminalResults[fileID] = event
        let outboxSaved = (try? persistOutbox()) != nil
        let stateSaved = (try? persistState()) != nil
        if !stateSaved { needsTerminalJournalRepair = true }
        if let task = tasks.removeValue(forKey: fileID), task.state != .completed {
            task.cancel()
        }
        permissions.removeValue(forKey: fileID)
        if outboxSaved && stateSaved, let name = stagingName { try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(name)) }
        deliver(event)
        Self.logger.notice("File \(fileID, privacy: .public) ended: \(kind.rawValue, privacy: .public)")
        if self.state?.isFinished == true {
            self.state = nil
            if outboxSaved && stateSaved { try? FileManager.default.removeItem(at: snapshotURL) }
        }
        publish()
        advanceQueue()
    }

    private func startValidation(fileID: String, stagingName: String) {
        guard !backgroundExecutionExpired, validatingFileID == nil, let state, let file = state.file(for: fileID),
              state.items[fileID]?.phase == .validating else { return }
        validatingFileID = fileID
        let permission = permissions[fileID] ?? LANStoragePermission()
        permissions[fileID] = permission
        let temporary = stagingRoot.appendingPathComponent(stagingName)
        let sessionID = state.offer.sessionID
        validationQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.storeFile(temporary, file, permission) }
            self.stateQueue.async {
                self.validatingFileID = nil
                let wasInterrupted = self.interruptedValidations.remove(ObjectIdentifier(permission)) != nil
                guard self.state?.offer.sessionID == sessionID,
                      self.state?.items[fileID]?.phase == .validating,
                      self.permissions[fileID] === permission else {
                    if self.state?.items[fileID]?.stagingName != stagingName || self.state?.items[fileID]?.phase.isPending != true {
                        try? FileManager.default.removeItem(at: temporary)
                    }
                    self.advanceQueue()
                    self.completeBackgroundEventsIfReady()
                    return
                }
                switch result {
                case .success: self.finish(fileID: fileID, kind: .stored, message: "歌曲已保存到手表")
                case .failure(let error):
                    if wasInterrupted, error is CancellationError {
                        self.permissions.removeValue(forKey: fileID)
                        Self.logger.notice("Validation deferred after background expiration")
                    } else {
                        self.finish(fileID: fileID, kind: error is CancellationError ? .cancelled : .failed, message: error.localizedDescription)
                    }
                }
                self.advanceQueue()
                self.completeBackgroundEventsIfReady()
            }
        }
    }

    private func publish() {
        let status = state.map(LANReceptionStatus.init(state:))
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentPublication(currentGeneration) else { return }
            self.onUpdate?(status)
        }
    }

    private func deliver(_ event: LANTransferEvent) {
        let currentGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !event.kind.isTerminal, !self.isCurrentPublication(currentGeneration) { return }
            self.onEvent?(event)
        }
    }

    private func isCurrentPublication(_ expected: UUID) -> Bool {
        generationLock.withLock { generation == expected }
    }

    private func emitProgress(_ file: LANTransferFile, message: String? = nil) {
        guard let state, let item = state.items[file.id] else { return }
        deliver(LANTransferEvent(sessionID: state.offer.sessionID, fileID: file.id, kind: item.phase == .paused ? .paused : .progress,
                                 completedBytes: item.receivedBytes, totalBytes: file.byteCount, message: message,
                                 controlRevision: item.controlRevision,
                                 automaticPause: item.lifecyclePaused == true ? true : nil))
    }

    private func completeBackgroundEventsIfReady() {
        guard backgroundEventsFinished, !reconcilingTasks, validatingFileID == nil,
              !backgroundCompletions.isEmpty else { return }
        completeBackgroundCompletions()
    }

    private func completeBackgroundCompletions() {
        let completions = backgroundCompletions
        backgroundCompletions = []
        backgroundEventsFinished = false
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard session === networkSession, let (file, _) = binding(downloadTask) else { return }
        if totalBytesWritten > file.byteCount {
            downloadTask.cancel()
            finish(fileID: file.id, kind: .failed, message: "接收大小超出歌曲清单，已停止。")
            return
        }
        guard state?.recordProgress(fileID: file.id, bytes: max(0, totalBytesWritten)) == true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSnapshotTime >= 1 { try? persistState() }
        if now - (lastProgressTime[file.id] ?? 0) >= 1 || totalBytesWritten == file.byteCount {
            lastProgressTime[file.id] = now
            emitProgress(file)
        }
        if now - lastUIProgressTime >= 0.2 || totalBytesWritten == file.byteCount {
            lastUIProgressTime = now
            publish()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // getAllTasks can omit an already-completed task before its completion
        // callback has been replayed. Its immutable manifest identity still
        // authorizes these bytes even if reconciliation created a replacement.
        // Progress and error callbacks continue to require the exact native ID.
        guard session === networkSession, let state,
              let identity = LANBackgroundTransferState.taskIdentity(downloadTask.taskDescription),
              identity.sessionID == state.offer.sessionID,
              let file = state.file(for: identity.fileID), let item = state.items[file.id],
              item.phase.isPending, item.stagingName == nil else { return }
        let isCurrentTask = item.taskIdentifier == downloadTask.taskIdentifier
        guard let response = downloadTask.response as? HTTPURLResponse,
              LANTransferValidation.isValidDownloadResponse(statusCode: response.statusCode,
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"), expectedByteCount: file.byteCount) else {
            guard isCurrentTask else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            failOrTryAnotherAddress(fileID: file.id, error: receiverError("局域网下载失败（HTTP \(status)）。"), mayRetry: status >= 500 || status == 0)
            return
        }
        // Check the actual endpoint before treating downloaded bytes as trusted.
        // Background sessions follow redirects without invoking the redirect
        // delegate. A changed endpoint can never publish bytes to the library.
        guard let finalURL = response.url, isAuthorizedURL(finalURL, fileID: file.id) else {
            if isCurrentTask { finish(fileID: file.id, kind: .failed, message: "下载地址发生变化，已拒绝保存。") }
            return
        }
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
            if let replacement = tasks.removeValue(forKey: file.id), replacement.taskIdentifier != downloadTask.taskIdentifier {
                replacement.cancel()
            }
            try persistState()
            emitProgress(file, message: self.state?.items[file.id]?.phase == .paused ? "已暂停" : "正在校验并保存")
            publish()
            advanceQueue()
        } catch {
            if isCurrentTask || self.state?.items[file.id]?.stagingName != nil {
                finish(fileID: file.id, kind: .failed, message: error.localizedDescription)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === networkSession else { return }
        guard let (file, _) = binding(task) else { return }
        tasks.removeValue(forKey: file.id)
        if state?.items[file.id]?.phase == .paused, error != nil {
            state?.items[file.id]?.taskIdentifier = nil
            try? persistState()
            publish()
            advanceQueue()
            return
        }
        if let error {
            Self.logger.error("Background download failed: \((error as NSError).code)")
            failOrTryAnotherAddress(fileID: file.id, error: error,
                                   mayRetry: (error as NSError).code != NSURLErrorCancelled)
        } else { finish(fileID: file.id, kind: .failed, message: "下载没有返回可保存的歌曲文件。") }
        completeBackgroundEventsIfReady()
    }

    /// Metrics arrive at transaction completion, not continuously during sleep.
    /// The proxy flag alone does not identify the Watch's companion transport.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard session === networkSession else { return }
        let identifier = session.configuration.identifier ?? "none"
        Self.logger.notice("Native task metrics: session \(identifier, privacy: .public), task \(task.taskIdentifier), transactions \(metrics.transactionMetrics.count), redirects \(metrics.redirectCount), startedAt \(metrics.taskInterval.start.timeIntervalSince1970), endedAt \(metrics.taskInterval.end.timeIntervalSince1970), received \(task.countOfBytesReceived), expected \(task.countOfBytesExpectedToReceive)")
        for (index, transaction) in metrics.transactionMetrics.enumerated() {
            let protocolName = transaction.networkProtocolName ?? "unknown"
            // A missing timestamp is logged as -1; no URL, host, request,
            // response description, token, or local/remote address is logged.
            let fetchStartedAt = transaction.fetchStartDate?.timeIntervalSince1970 ?? -1
            let connectionStartedAt = transaction.connectStartDate?.timeIntervalSince1970 ?? -1
            let connectionEndedAt = transaction.connectEndDate?.timeIntervalSince1970 ?? -1
            let requestStartedAt = transaction.requestStartDate?.timeIntervalSince1970 ?? -1
            let requestEndedAt = transaction.requestEndDate?.timeIntervalSince1970 ?? -1
            let responseStartedAt = transaction.responseStartDate?.timeIntervalSince1970 ?? -1
            let responseEndedAt = transaction.responseEndDate?.timeIntervalSince1970 ?? -1
            Self.logger.notice("Native transaction metrics: task \(task.taskIdentifier), transaction \(index), protocol \(protocolName, privacy: .public), proxy \(transaction.isProxyConnection), receivedBody \(transaction.countOfResponseBodyBytesReceived), decodedBody \(transaction.countOfResponseBodyBytesAfterDecoding), fetchAt \(fetchStartedAt), connectStartAt \(connectionStartedAt), connectEndAt \(connectionEndedAt), requestStartAt \(requestStartedAt), requestEndAt \(requestEndedAt), responseStartAt \(responseStartedAt), responseEndAt \(responseEndedAt)")
        }
    }

    private func failOrTryAnotherAddress(fileID: String, error: Error, mayRetry: Bool) {
        guard let state, let item = state.items[fileID] else { return }
        if let task = tasks.removeValue(forKey: fileID), task.state != .completed {
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
        backgroundEventsFinished = true
        Self.logger.notice("Background URLSession delivered its pending events")
        advanceQueue()
        completeBackgroundEventsIfReady()
    }

    private func receiverError(_ message: String) -> NSError {
        NSError(domain: "LANDownloadReceiver", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
