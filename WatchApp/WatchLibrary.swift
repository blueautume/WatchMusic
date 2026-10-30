import AVFoundation
import Foundation
import WatchConnectivity
import WatchKit

struct MusicFolder: Identifiable, Hashable {
    let name: String
    let tracks: [URL]
    var id: String { name }
}

/// The watch owns a complete local library; the phone is only needed to add files.
/// Disk mutations are serial, and WC temporary files are saved before returning.
final class WatchLibrary: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLibrary()
    @Published private(set) var folders: [MusicFolder] = []
    @Published private(set) var connectionStatus = "本地音乐可离线播放"
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var availableBytes: Int64 = 0
    @Published private(set) var isReceiving = false
    @Published private(set) var lanReception: LANReceptionStatus?
    @Published private(set) var lastTransferMessage: String?
    @Published private(set) var lastReceivedAt: Date?
    @Published var errorMessage: String?
    var allTracks: [URL] { folders.flatMap(\.tracks) }
    var trackCount: Int { allTracks.count }

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.lihao.WatchMusic.watch-library", qos: .utility)
    private let receiveLock = NSLock()
    private var receivingCount = 0
    private var lanReservedPaths = Set<String>()
    private var nativeReservedPaths = Set<String>()
    private let rootURL: URL
    private let lanInventory: LANInventory
    private var session: WCSession?
    private var activationFinished = false
    private var pendingTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var pendingURLSessionTasks: [ObjectIdentifier: WKURLSessionRefreshBackgroundTask] = [:]
    private var pendingObservation: NSKeyValueObservation?
    private var lanReceiver: LANDownloadReceiver!
    private var lanFiles: [String: LANTransferFile] = [:]
    private var lanSessionID: String?
    private var lanAppForeground = false
    #if DEBUG
    private var debugLANEvents: [LANTransferEvent] = []
    private var debugLANEventLog: URL?
    private var debugLANSessionID: String?
    private var debugLANLifecycleLog: URL?
    private var debugLANLifecycleEvents: [[String: Any]] = []
    private var didStartLANPreview = false
    #endif

    override init() {
        rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music", isDirectory: true)
        lanInventory = LANInventory(rootURL: rootURL)
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lan-record-lifecycle") {
            configureLANEventLog(reset: false)
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let lifecycleLog = documents.appendingPathComponent("lan-lifecycle-events.json")
            debugLANLifecycleLog = lifecycleLog
            if let data = try? Data(contentsOf: lifecycleLog), data.count <= 4_194_304,
               let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                debugLANLifecycleEvents = items
            }
            appendLANLifecycleEvent("processStarted")
        } else if ProcessInfo.processInfo.arguments.contains("-lan-restore-events") {
            configureLANEventLog(reset: false)
        }
        #endif
        lanReceiver = LANDownloadReceiver { [weak self] temporary, file, permission in
            guard let self else { throw CancellationError() }
            try self.ioQueue.sync {
                try self.storeAudio(at: temporary, folder: file.folder, fileName: file.fileName,
                                    expected: file, permission: permission)
            }
        }
        lanReceiver.onUpdate = { [weak self] status in
            guard let self else { return }
            self.lanReception = status
            if status == nil {
                #if DEBUG
                self.appendLANLifecycleEvent("sessionFinished")
                #endif
                self.lanSessionID = nil
                self.lanFiles = [:]
                self.receiveLock.lock(); self.lanReservedPaths.removeAll(); self.receiveLock.unlock()
            }
            self.updateReceivingState()
        }
        lanReceiver.onEvent = { [weak self] event in self?.reportLANEvent(event) }
        if let restored = lanReceiver.restore() {
            lanSessionID = restored.sessionID
            lanFiles = Dictionary(uniqueKeysWithValues: restored.files.map { ($0.id, $0) })
            #if DEBUG
            if debugLANEventLog != nil { debugLANSessionID = restored.sessionID }
            appendLANLifecycleEvent("sessionRestored")
            #endif
            let pendingIDs = lanReceiver.pendingFileIDs
            receiveLock.lock()
            lanReservedPaths = Set(restored.files.filter { pendingIDs.contains($0.id) }.map {
                ($0.folder + "/" + $0.fileName).precomposedStringWithCanonicalMapping.lowercased()
            })
            receiveLock.unlock()
            updateReceivingState()
        }
        refresh()
        if WCSession.isSupported() {
            let session = WCSession.default
            self.session = session
            session.delegate = self
            pendingObservation = session.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.completeBackgroundTasksIfPossible() }
            }
            session.activate()
        } else { activationFinished = true }
    }

    func refresh() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
                let directories = try self.fileManager.contentsOfDirectory(at: self.rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                var size: Int64 = 0
                let folders = directories.compactMap { directory -> MusicFolder? in
                    guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let entries = try? self.fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
                    let tracks = entries.filter { url in
                        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return false }
                        size += Int64(values.fileSize ?? 0)
                        return AudioFileFormat.supports(url)
                    }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    return MusicFolder(name: directory.lastPathComponent, tracks: tracks)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let free = self.freeSpace()
                DispatchQueue.main.async { self.folders = folders; self.totalBytes = size; self.availableBytes = free }
            } catch { DispatchQueue.main.async { self.errorMessage = "读取音乐失败：\(error.localizedDescription)" } }
        }
    }

    func createFolder(_ input: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let name = safeComponent(input), name.utf8.count <= 180 else { fail("请输入有效且较短的目录名称。", completion: completion); return }
        mutate(completion: completion) {
            let destination = self.rootURL.appendingPathComponent(name, isDirectory: true)
            guard !self.fileManager.fileExists(atPath: destination.path) else { throw self.libraryError("该目录已存在") }
            try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        }
    }

    func renameFolder(_ oldName: String, to input: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let oldName = safeComponent(oldName), let name = safeComponent(input), name.utf8.count <= 180 else { fail("目录名称无效。", completion: completion); return }
        if oldName == name { completion(true); return }
        mutate(completion: completion) {
            let source = self.rootURL.appendingPathComponent(oldName, isDirectory: true)
            let destination = self.rootURL.appendingPathComponent(name, isDirectory: true)
            guard !self.fileManager.fileExists(atPath: destination.path) else { throw self.libraryError("该目录已存在") }
            try self.fileManager.moveItem(at: source, to: destination)
        }
    }

    func renameTrack(_ track: URL, to input: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard owns(track), let name = safeComponent(input), name.utf8.count <= 180,
              let format = AudioFileFormat.format(for: track) else { fail("歌曲名称无效。", completion: completion); return }
        let destination = track.deletingLastPathComponent().appendingPathComponent(AudioFileFormat.fileName(stem: name, format: format))
        moveTrackFiles(track, to: destination, completion: completion)
    }

    func moveTrack(_ track: URL, to folder: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard owns(track), let folder = safeComponent(folder) else { fail("目标目录无效。", completion: completion); return }
        let destination = rootURL.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(track.lastPathComponent)
        moveTrackFiles(track, to: destination, completion: completion)
    }

    private func moveTrackFiles(_ track: URL, to destination: URL, completion: @escaping (Bool) -> Void) {
        if destination.standardizedFileURL == track.standardizedFileURL { completion(true); return }
        mutate(completion: completion) {
            guard !self.fileManager.fileExists(atPath: destination.path) else { throw self.libraryError("目标位置有同名歌曲，请先重命名") }
            guard self.fileManager.fileExists(atPath: destination.deletingLastPathComponent().path) else { throw self.libraryError("目标目录已不存在") }
            try self.fileManager.moveItem(at: track, to: destination)
        }
    }

    func deleteTrack(_ track: URL, completion: @escaping (Bool) -> Void = { _ in }) {
        guard owns(track) else { fail("歌曲位置无效。", completion: completion); return }
        mutate(completion: completion) {
            try self.fileManager.removeItem(at: track)
        }
    }

    func deleteFolder(_ input: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let name = safeComponent(input) else { fail("目录名称无效。", completion: completion); return }
        mutate(completion: completion) { try self.fileManager.removeItem(at: self.rootURL.appendingPathComponent(name, isDirectory: true)) }
    }

    private func owns(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL
    }
    private func fail(_ message: String, completion: (Bool) -> Void) { errorMessage = message; completion(false) }
    private func mutate(completion: @escaping (Bool) -> Void = { _ in }, _ action: @escaping () throws -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.receiveLock.lock()
                let receiving = self.receivingCount > 0 || !self.lanReservedPaths.isEmpty
                self.receiveLock.unlock()
                guard !receiving else { throw self.libraryError("正在接收歌曲，请完成或取消后再管理音乐。") }
                try action(); self.refresh(); DispatchQueue.main.async { completion(true) }
            }
            catch { DispatchQueue.main.async { self.errorMessage = "操作失败：\(error.localizedDescription)"; completion(false) } }
        }
    }

    func addBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        DispatchQueue.main.async { self.pendingTasks.append(task); self.completeBackgroundTasksIfPossible() }
    }

    /// The system-owned download continues after this wake cycle ends. Only
    /// this delivery batch and any completed-file validation must be drained.
    func addURLSessionBackgroundTask(_ task: WKURLSessionRefreshBackgroundTask) {
        DispatchQueue.main.async { [self, task] in
            guard task.sessionIdentifier == LANDownloadReceiver.backgroundSessionIdentifier else {
                task.setTaskCompletedWithSnapshot(false)
                return
            }
            let id = ObjectIdentifier(task)
            guard self.pendingURLSessionTasks[id] == nil else { return }
            self.pendingURLSessionTasks[id] = task
            #if DEBUG
            self.appendLANLifecycleEvent("backgroundEventsReceived")
            #endif
            task.expirationHandler = { [weak self, weak task] in
                guard let task else { return }
                DispatchQueue.main.async { self?.completeURLSessionBackgroundTask(task, expired: true) }
            }
            self.lanReceiver.handleBackgroundEvents(identifier: task.sessionIdentifier) { [weak self, weak task] in
                guard let task else { return }
                DispatchQueue.main.async { self?.completeURLSessionBackgroundTask(task) }
            }
        }
    }

    private func completeURLSessionBackgroundTask(_ task: WKURLSessionRefreshBackgroundTask, expired: Bool = false) {
        guard let pending = pendingURLSessionTasks.removeValue(forKey: ObjectIdentifier(task)) else { return }
        #if DEBUG
        appendLANLifecycleEvent(expired ? "backgroundEventsExpired" : "backgroundEventsCompleted")
        #endif
        pending.expirationHandler = nil
        pending.setTaskCompletedWithSnapshot(false)
    }
    private func completeBackgroundTasksIfPossible() {
        guard activationFinished else { return }
        receiveLock.lock(); let hasReceives = receivingCount > 0; receiveLock.unlock()
        guard !hasReceives else { return }
        if let session, session.activationState == .activated, session.hasContentPending { return }
        let tasks = pendingTasks; pendingTasks.removeAll()
        tasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
    }
    private func freeSpace() -> Int64 {
        let attributes = try? fileManager.attributesOfFileSystem(forPath: rootURL.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    private func safeComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LANTransferValidation.isSafeComponent(trimmed) else { return nil }
        return trimmed
    }
    private func updateConnectionStatus() {
        guard let session, session.activationState == .activated else { connectionStatus = "本地音乐可离线播放"; return }
        connectionStatus = session.isReachable ? "手机在线，可接收音乐" : "本地音乐可离线播放"
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activationFinished = true; self.updateConnectionStatus()
            if let error { self.lastTransferMessage = "手机连接暂不可用：\(error.localizedDescription)" }
            if activationState == .activated { self.lanReceiver.replayTerminalEvents() }
            self.completeBackgroundTasksIfPossible()
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.updateConnectionStatus()
            if session.activationState == .activated { self.lanReceiver.replayTerminalEvents() }
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let transferID = metadata["transferID"] as? String ?? ""
        let folder = (metadata["folder"] as? String).flatMap(safeComponent)
        let name = (metadata["fileName"] as? String).flatMap(safeComponent)
        let path = folder.flatMap { folder in name.map { (folder + "/" + $0).precomposedStringWithCanonicalMapping.lowercased() } }
        receiveLock.lock()
        receivingCount += 1
        let conflict = path.map { lanReservedPaths.contains($0) || nativeReservedPaths.contains($0) } ?? false
        if let path, !conflict { nativeReservedPaths.insert(path) }
        receiveLock.unlock()
        DispatchQueue.main.async { self.updateReceivingState() }
        var receipt: [String: Any] = ["type": "receipt", "transferID": transferID]
        do {
            guard !transferID.isEmpty, let folder, let name else { throw libraryError("目录名、文件名或传输标识无效") }
            guard !conflict else { throw libraryError("同名歌曲正在接收，请完成后重试") }
            guard (metadata["kind"] as? String ?? "audio") == "audio" else { throw libraryError("仅支持音频文件") }
            try ioQueue.sync { try storeAudio(at: file.fileURL, folder: folder, fileName: name) }
            receipt["success"] = true; receipt["message"] = "歌曲已保存到手表"
            DispatchQueue.main.async {
                self.lastTransferMessage = "已收到：\((name as NSString).deletingPathExtension)"
                self.lastReceivedAt = Date()
            }
            refresh()
        } catch {
            receipt["success"] = false; receipt["message"] = error.localizedDescription
            DispatchQueue.main.async { self.lastTransferMessage = "接收失败"; self.errorMessage = "保存文件失败：\(error.localizedDescription)" }
        }
        if !transferID.isEmpty, session.activationState == .activated { session.transferUserInfo(receipt) }
        receiveLock.lock()
        receivingCount -= 1
        if let path, !conflict { nativeReservedPaths.remove(path) }
        receiveLock.unlock()
        DispatchQueue.main.async { self.updateReceivingState(); self.completeBackgroundTasksIfPossible() }
    }

    func updateLANForeground(_ foreground: Bool) {
        lanAppForeground = foreground
        lanInventory.setForeground(foreground)
        lanReceiver.setForeground(foreground)
        // Inactive/blank-screen states pause LAN work until a fresh phone offer.
    }

    func cancelLANTransfer() { lanReceiver.stop() }

    private func updateReceivingState() {
        receiveLock.lock()
        let nativeReceiving = receivingCount > 0
        let lanReceiving = !lanReservedPaths.isEmpty
        receiveLock.unlock()
        isReceiving = nativeReceiving || lanReceiving || lanReception != nil
    }

    private func receiveLANOffer(_ offer: LANTransferOffer, allowLoopbackForTesting: Bool = false) throws {
        guard lanAppForeground else { throw libraryError("请先在手表上打开 App，再开始局域网传输。") }
        try LANTransferValidation.validate(offer, allowLoopback: allowLoopbackForTesting)
        guard lanSessionID == nil else { throw libraryError("手表正在接收另一批歌曲，请完成或取消后重试。") }
        let paths = Set(offer.files.map { ($0.folder + "/" + $0.fileName).precomposedStringWithCanonicalMapping.lowercased() })
        receiveLock.lock()
        let conflicts = !nativeReservedPaths.isDisjoint(with: paths) || !lanReservedPaths.isEmpty
        if !conflicts { lanReservedPaths = paths }
        receiveLock.unlock()
        guard !conflicts else { throw libraryError("同名歌曲正在保存，请稍后重试。") }
        lanSessionID = offer.sessionID
        lanFiles = Dictionary(uniqueKeysWithValues: offer.files.map { ($0.id, $0) })
        #if DEBUG
        if debugLANLifecycleLog != nil {
            configureLANEventLog(reset: true)
            debugLANSessionID = offer.sessionID
        }
        appendLANLifecycleEvent("offerAccepted")
        #endif
        do { try lanReceiver.accept(offer, allowLoopbackForTesting: allowLoopbackForTesting) }
        catch {
            lanSessionID = nil; lanFiles = [:]
            receiveLock.lock(); lanReservedPaths.removeAll(); receiveLock.unlock()
            throw error
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            if let request = LANTransferWire.decode(LANInventoryRequest.self, from: message, type: LANInventoryWire.requestType) {
                self.lanInventory.matching(request) { result in
                    switch result {
                    case .success(let reply):
                        replyHandler((try? LANTransferWire.message(reply, type: LANInventoryWire.replyType)) ?? ["accepted": false])
                    case .failure(let error):
                        if error is CancellationError {
                            replyHandler(["accepted": false, "retryable": true, "message": "等待手表 App 打开后继续"])
                        } else {
                            replyHandler(["accepted": false, "message": "无法检查手表已存歌曲，请重试。"])
                        }
                    }
                }
            } else if let offer = LANTransferWire.decode(LANTransferOffer.self, from: message, type: LANTransferWire.offerType) {
                do { try self.receiveLANOffer(offer); replyHandler(["accepted": true]) }
                catch { replyHandler(["accepted": false, "message": error.localizedDescription]) }
            } else if let command = LANTransferWire.decode(LANTransferCommand.self, from: message, type: LANTransferWire.commandType) {
                self.lanReceiver.handle(command) { events in
                    replyHandler((try? LANTransferWire.message(LANTransferControlReply(events: events), type: LANTransferWire.controlReplyType)) ?? ["accepted": false])
                }
            } else { replyHandler(["accepted": false, "message": "无法识别局域网传输信息。 "]) }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            guard let command = LANTransferWire.decode(LANTransferCommand.self, from: message, type: LANTransferWire.commandType) else { return }
            self.lanReceiver.handle(command)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = LANTransferWire.decode(LANTransferCommand.self, from: userInfo, type: LANTransferWire.commandType) else { return }
        lanReceiver.handle(command)
    }

    private func reportLANEvent(_ event: LANTransferEvent) {
        let belongsToCurrentSession = event.sessionID == lanSessionID
        guard event.kind.isTerminal || belongsToCurrentSession else { return }
        if event.kind.isTerminal, belongsToCurrentSession, let file = lanFiles[event.fileID] {
            receiveLock.lock(); lanReservedPaths.remove((file.folder + "/" + file.fileName).precomposedStringWithCanonicalMapping.lowercased()); receiveLock.unlock()
            if event.kind == .stored {
                lastTransferMessage = "已收到：\((file.fileName as NSString).deletingPathExtension)"
                lastReceivedAt = Date()
                refresh()
            } else { lastTransferMessage = event.message ?? "局域网传输已停止" }
        } else if event.kind == .stored {
            // A durable save result may be replayed after the session UI was
            // cleared, or after the process was relaunched by the system.
            lastReceivedAt = Date()
            if lanSessionID == nil { lastTransferMessage = event.message ?? "歌曲已保存到手表" }
            refresh()
        }
        #if DEBUG
        if event.kind.isTerminal {
            appendLANLifecycleEvent(event.kind.rawValue, sessionID: event.sessionID, fileID: event.fileID)
        }
        if let debugLANEventLog, event.sessionID == debugLANSessionID {
            debugLANEvents.append(event)
            if let data = try? JSONEncoder().encode(debugLANEvents) { try? data.write(to: debugLANEventLog, options: .atomic) }
        }
        #endif
        guard let message = try? LANTransferWire.message(event, type: LANTransferWire.eventType),
              let session, session.activationState == .activated else { return }
        if event.kind.isTerminal || event.automaticPause == true {
            session.transferUserInfo(message)
            // The OS now owns a durable copy. Before activation the receiver
            // keeps its protected outbox and replays it on the next wake.
            if event.kind.isTerminal { lanReceiver.acknowledgeTerminalEvent(sessionID: event.sessionID, fileID: event.fileID) }
        }
        if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
    }

    /// Called only on ioQueue. Optional LAN integrity checks happen before any
    /// destination changes, and the final move is guarded against cancellation.
    private func storeAudio(at temporary: URL, folder: String, fileName: String,
                            expected: LANTransferFile? = nil, permission: LANStoragePermission? = nil) throws {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-lan-offer-file"), let flag = arguments.firstIndex(of: "-lan-save-delay"),
           arguments.indices.contains(flag + 1), let seconds = Double(arguments[flag + 1]),
           seconds.isFinite, (0.1...10).contains(seconds) { Thread.sleep(forTimeInterval: seconds) }
        #endif
        try permission?.check()
        guard LANTransferValidation.isSafeComponent(folder), LANTransferValidation.isSafeComponent(fileName),
              AudioFileFormat.supports(URL(fileURLWithPath: fileName)) else { throw libraryError("不支持的歌曲文件或目录名称") }
        let values = try temporary.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        let size = Int64(values.fileSize ?? 0)
        guard values.isRegularFile == true, values.isSymbolicLink != true, size > 0 else { throw libraryError("接收的文件为空或不可读取") }
        if let expected {
            guard size == expected.byteCount else { throw libraryError("接收的歌曲大小不符，请重新发送") }
            let hash = try LANFileDigest.sha256(of: temporary) { try permission?.check() }
            guard hash == expected.sha256.lowercased() else { throw libraryError("歌曲完整性校验失败，请重新发送") }
        }
        let free = freeSpace()
        if free > 0, free < size + 5 * 1_024 * 1_024 { throw libraryError("手表空间不足，请先删除一些歌曲") }
        let probe = try AVAudioPlayer(contentsOf: temporary)
        guard probe.duration.isFinite, probe.duration > 0 else { throw libraryError("文件不是手表可解码的 MP3 或 FLAC") }
        try permission?.check()
        try secureDirectory(rootURL, parent: rootURL.deletingLastPathComponent())
        let directory = rootURL.appendingPathComponent(folder, isDirectory: true)
        try secureDirectory(directory, parent: rootURL)
        let destination = directory.appendingPathComponent(fileName)
        try validateDestination(destination, directory: directory)
        let staging = directory.appendingPathComponent(".incoming-" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: temporary, to: staging)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        let commit = {
            try self.validateDestination(destination, directory: directory)
            if self.fileManager.fileExists(atPath: destination.path) { _ = try self.fileManager.replaceItemAt(destination, withItemAt: staging) }
            else { try self.fileManager.moveItem(at: staging, to: destination) }
        }
        if let permission { try permission.commit(commit) } else { try commit() }
        if let expected { lanInventory.recordValidated(expected) }
    }

    private func secureDirectory(_ directory: URL, parent: URL) throws {
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        guard directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == parentPath else { throw libraryError("保存目录位置无效") }
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw libraryError("保存目录不是有效的本地目录") }
        } else { try fileManager.createDirectory(at: directory, withIntermediateDirectories: false) }
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == parentPath else { throw libraryError("保存目录超出音乐库") }
    }

    private func validateDestination(_ destination: URL, directory: URL) throws {
        guard destination.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else { throw libraryError("歌曲保存位置无效") }
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw libraryError("同名位置不是有效的本地歌曲") }
        }
    }

    #if DEBUG
    /// Observation only: the App passes actual SwiftUI scene phase changes here.
    func recordLANScenePhase(_ phase: String) {
        appendLANLifecycleEvent("scenePhase", phase: phase)
    }

    private func appendLANLifecycleEvent(_ event: String, phase: String? = nil,
                                         sessionID: String? = nil, fileID: String? = nil) {
        guard let debugLANLifecycleLog else { return }
        var item: [String: Any] = ["event": event, "timestamp": Date().timeIntervalSince1970]
        if let phase { item["phase"] = phase }
        if let sessionID = sessionID ?? lanSessionID { item["sessionID"] = sessionID }
        if let fileID { item["fileID"] = fileID }
        debugLANLifecycleEvents.append(item)
        if debugLANLifecycleEvents.count > 4_096 { debugLANLifecycleEvents.removeFirst(debugLANLifecycleEvents.count - 4_096) }
        if let data = try? JSONSerialization.data(withJSONObject: debugLANLifecycleEvents) {
            try? data.write(to: debugLANLifecycleLog, options: .atomic)
        }
    }

    private func configureLANEventLog(reset: Bool) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let log = documents.appendingPathComponent("lan-test-events.json")
        debugLANEventLog = log
        if !reset, let data = try? Data(contentsOf: log), data.count <= 4_194_304,
           let restored = try? JSONDecoder().decode([LANTransferEvent].self, from: data) {
            debugLANEvents = restored
            debugLANSessionID = restored.last?.sessionID
        } else {
            debugLANEvents = []
            debugLANSessionID = nil
            try? Data("[]".utf8).write(to: log, options: .atomic)
        }
    }

    /// Real HTTP downloads for simulator verification; test data stays in Documents.
    func startLANPreviewIfRequested() {
        guard !didStartLANPreview, lanAppForeground else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-lan-offer-file"), arguments.indices.contains(index + 1),
              let name = safeComponent(arguments[index + 1]) else { return }
        didStartLANPreview = true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        configureLANEventLog(reset: true)
        do {
            let offer = try JSONDecoder().decode(LANTransferOffer.self, from: Data(contentsOf: documents.appendingPathComponent(name)))
            debugLANSessionID = offer.sessionID
            try receiveLANOffer(offer, allowLoopbackForTesting: true)
            if let flag = arguments.firstIndex(of: "-lan-background-after"), arguments.indices.contains(flag + 1),
               let seconds = Double(arguments[flag + 1]), seconds.isFinite, (0.1...60).contains(seconds) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self, self.lanSessionID == offer.sessionID else { return }
                    self.updateLANForeground(false)
                    let marker = documents.appendingPathComponent("lan-test-background.json")
                    if let data = try? JSONSerialization.data(withJSONObject: ["enteredBackground": true, "simulated": true, "sessionID": offer.sessionID]) {
                        try? data.write(to: marker, options: .atomic)
                    }
                }
            }
            if let flag = arguments.firstIndex(of: "-lan-foreground-after"), arguments.indices.contains(flag + 1),
               let seconds = Double(arguments[flag + 1]), seconds.isFinite, (0.1...60).contains(seconds) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.updateLANForeground(true)
                }
            }
            if let flag = arguments.firstIndex(of: "-lan-replacement-after"), arguments.indices.contains(flag + 1),
               let seconds = Double(arguments[flag + 1]), seconds.isFinite, (0.1...60).contains(seconds),
               let nextFlag = arguments.firstIndex(of: "-lan-next-offer-file"), arguments.indices.contains(nextFlag + 1),
               let nextName = safeComponent(arguments[nextFlag + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self, self.lanAppForeground else { return }
                    do {
                        let replacement = try JSONDecoder().decode(LANTransferOffer.self, from: Data(contentsOf: documents.appendingPathComponent(nextName)))
                        self.lanReceiver.handle(LANTransferCommand(sessionID: offer.sessionID, kind: .stop, fileID: nil)) { [weak self] _ in
                            guard let self else { return }
                            // Keep both sessions in the probe log to audit the
                            // pause/ready boundary and the fresh-session save.
                            self.debugLANSessionID = replacement.sessionID
                            do { try self.receiveLANOffer(replacement, allowLoopbackForTesting: true) }
                            catch { self.errorMessage = error.localizedDescription }
                        }
                    } catch { self.errorMessage = error.localizedDescription }
                }
            }
            if let flag = arguments.firstIndex(of: "-lan-cancel-after"), arguments.indices.contains(flag + 1),
               let seconds = Double(arguments[flag + 1]), seconds.isFinite, (0.1...60).contains(seconds) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard self?.lanSessionID == offer.sessionID else { return }
                    self?.cancelLANTransfer()
                }
            }
            if let flag = arguments.firstIndex(of: "-lan-cancel-first-after"), arguments.indices.contains(flag + 1),
               let seconds = Double(arguments[flag + 1]), seconds.isFinite, (0.1...60).contains(seconds),
               let first = offer.files.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self, self.lanSessionID == offer.sessionID else { return }
                    self.lanReceiver.handle(LANTransferCommand(sessionID: offer.sessionID, kind: .cancel,
                                                              fileID: first.id))
                }
            }
            for (option, kind, revision) in [("-lan-pause-after", LANTransferCommand.Kind.pause, 1),
                                              ("-lan-resume-after", LANTransferCommand.Kind.resume, 2)] {
                if let flag = arguments.firstIndex(of: option), arguments.indices.contains(flag + 1),
                   let seconds = Double(arguments[flag + 1]), seconds.isFinite, (0.1...60).contains(seconds) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                        guard let self, self.lanSessionID == offer.sessionID else { return }
                        self.lanReceiver.handle(LANTransferCommand(sessionID: offer.sessionID, kind: kind,
                                                                  fileID: nil, controlRevision: Int64(revision)))
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    #endif

    private func libraryError(_ message: String) -> NSError { NSError(domain: "WatchLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
