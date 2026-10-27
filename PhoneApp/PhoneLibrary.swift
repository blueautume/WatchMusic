import AVFoundation
import Combine
import Foundation
import WatchConnectivity
import UIKit

struct PhoneFolder: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct PhoneTrack: Identifiable, Hashable {
    let folder: String
    let fileName: String
    let url: URL
    var bytes: Int64 = 0
    var duration: Double = 0
    var id: String { folder + "/" + fileName }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var formatName: String { AudioFileFormat.format(for: url)?.displayName ?? url.pathExtension.uppercased() }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum TransferMethod: String, Codable, CaseIterable, Identifiable {
    case localNetwork, system
    var id: String { rawValue }
    var title: String { self == .system ? "普通" : "局域网" }
}

struct TransferRecord: Identifiable, Codable, TransferListRecord {
    typealias State = TransferRecordState
    let id: String
    let folder: String
    let fileName: String
    let createdAt: Date
    var state: State
    var message: String
    var totalBytes: Int64 = 0
    var transport: TransferMethod? = nil
    var lanSessionID: String? = nil
    var method: TransferMethod { transport ?? .system }
    var audioFileName: String { fileName }
    var songTitle: String { (fileName as NSString).deletingPathExtension }

}

@MainActor
final class PhoneLibrary: NSObject, ObservableObject {
    @Published private(set) var isPreparingLAN = false
    @Published private(set) var activeLANSessionID: String?
    @Published private(set) var lanStatus = ""
    @Published private(set) var folders: [PhoneFolder] = []
    @Published private(set) var transfers: [TransferRecord] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var transferMetrics: [String: TransferMetrics] = [:]
    @Published private(set) var connectionDescription = "正在连接 Apple Watch…"
    @Published private(set) var canSend = false
    @Published private(set) var isImporting = false
    @Published private(set) var importMessage = ""
    @Published private(set) var importProgress: Double = 0
    @Published private(set) var importSummary: String?
    @Published var errorMessage: String?
    @Published private var trackIndex: [String: [PhoneTrack]] = [:]

    private let root: URL
    private let transferIndex: URL
    private var timer: AnyCancellable?
    private var durationCache: [String: Double] = [:]
    private var durationTask: Task<Void, Never>?
    private var progressSamplers: [String: TransferProgressSampler] = [:]
    private let fileManager = FileManager.default
    private var lanGeneration = UUID()
    private var lanPreparationTask: Task<Void, Never>?
    private var lanHandshakeTimeout: Task<Void, Never>?
    private var lanHandshakeAccepted = false
    private var lanRecordIDs = Set<String>()
    private var lanCompletedBytes: [String: Int64] = [:]
    private var savedIdleTimerDisabled: Bool?
    private var isAppForeground = true
    @Published private(set) var isUpdatingTransferControls = false
    private var transferControlRevision: Int64 = 0
    private var expectedControlRevisions: [String: Int64] = [:]
    private var transferControlGeneration = UUID()
    private var transferControlTask: Task<Void, Never>?
    private var restartTransferTask: Task<Void, Never>?
    private var pendingSendCompletion: LANEnqueueCompletion?
    #if DEBUG
    private var hasRunLANProbe = false
    private var lanProbeWaitTask: Task<Void, Never>?
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private let isTransferListPreview = ProcessInfo.processInfo.arguments.contains("-preview-transfers-in-progress") ||
        ProcessInfo.processInfo.arguments.contains("-preview-transfers-completed")
    private var didPrepareTransferListPreview = false
    #endif
    private lazy var lanServer: LANHTTPServer = {
        let server = LANHTTPServer()
        server.onStopped = { [weak self] message in
            self?.stopLANTransfers(message: message, state: .failed, notifyWatch: false)
        }
        return server
    }()

    var isLANActive: Bool { isPreparingLAN || activeLANSessionID != nil }
    var isAwaitingLANAcceptance: Bool { activeLANSessionID != nil && !lanHandshakeAccepted }
    var activeTransfers: [TransferRecord] {
        TransferListOrdering.activeTransfers(transfers, metrics: transferMetrics, completedBytes: lanCompletedBytes)
    }
    var storedTransfers: [TransferRecord] { TransferListOrdering.storedTransfers(transfers) }

    var allTracks: [PhoneTrack] { folders.flatMap { tracks(in: $0) } }
    var totalBytes: Int64 { allTracks.reduce(0) { $0 + $1.bytes } }
    var pendingCount: Int { transfers.filter { $0.state.isPending }.count }
    var storedCount: Int { Set(transfers.filter { $0.state == .stored }.map { $0.folder + "/" + $0.fileName }).count }
    var storageDescription: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    override init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        transferIndex = documents.appendingPathComponent("transfers.json")
        super.init()
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return }
        #endif
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("默认目录", isDirectory: true), withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: transferIndex) {
                transfers = (try? JSONDecoder().decode([TransferRecord].self, from: data)) ?? []
                // Local HTTP sessions and credentials never survive process termination.
                for index in transfers.indices where transfers[index].method == .localNetwork && transfers[index].state.isPending {
                    transfers[index].state = .failed
                    transfers[index].message = "局域网会话已结束，请重新发送。"
                }
                saveTransfers()
            }
            refreshFolders()
        } catch { errorMessage = "无法打开音乐目录：\(error.localizedDescription)" }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refreshProgress() }
        } else { connectionDescription = "此设备不支持 Apple Watch 连接" }
    }

    func tracks(in folder: PhoneFolder) -> [PhoneTrack] { trackIndex[folder.name] ?? [] }

    func refreshFolders() {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return }
        #endif
        do {
            let directories = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            folders = directories.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { PhoneFolder(name: $0.lastPathComponent) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var index: [String: [PhoneTrack]] = [:]
            for folder in folders {
                let url = root.appendingPathComponent(folder.name, isDirectory: true)
                index[folder.name] = ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
                    .filter { AudioFileFormat.supports($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .map { PhoneTrack(folder: folder.name, fileName: $0.lastPathComponent, url: $0, bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), duration: durationCache[$0.path] ?? 0) }
                    .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            }
            trackIndex = index
            loadDurations()
        } catch { errorMessage = "读取音乐目录失败：\(error.localizedDescription)" }
    }

    private func loadDurations() {
        durationTask?.cancel()
        let tracks = allTracks.filter { durationCache[$0.url.path] == nil }
        durationTask = Task { [weak self] in
            for track in tracks {
                guard !Task.isCancelled else { return }
                let duration = await Task.detached(priority: .utility) {
                    try? AVAudioPlayer(contentsOf: track.url).duration
                }.value
                if let duration, duration.isFinite {
                    guard let self, !Task.isCancelled else { return }
                    self.durationCache[track.url.path] = max(0, duration)
                    if let i = self.trackIndex[track.folder]?.firstIndex(where: { $0.id == track.id }) {
                        self.trackIndex[track.folder]?[i].duration = max(0, duration)
                    }
                }
            }
        }
    }

    private func validatedName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), !name.contains("\\"), name.utf8.count <= 180 else {
            errorMessage = "名称不能为空、不能以点开头，也不能包含 /、: 或反斜杠。请使用较短的名称。"
            return nil
        }
        return name
    }

    @discardableResult func createFolder(_ input: String) -> Bool {
        guard !isImporting, let name = validatedName(input) else { return false }
        let url = root.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: url.path) else { errorMessage = "该目录已存在。"; return false }
        do { try fileManager.createDirectory(at: url, withIntermediateDirectories: false); refreshFolders(); return true }
        catch { errorMessage = "创建目录失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult func renameFolder(_ folder: PhoneFolder, to input: String) -> Bool {
        guard canChange(tracks(in: folder)), let name = validatedName(input) else { return false }
        if name == folder.name { return true }
        let destination = root.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { errorMessage = "该目录已存在。"; return false }
        do { try fileManager.moveItem(at: root.appendingPathComponent(folder.name), to: destination); refreshFolders(); return true }
        catch { errorMessage = "重命名失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult func deleteFolder(_ folder: PhoneFolder) -> Bool {
        guard canChange(tracks(in: folder)) else { return false }
        do {
            try fileManager.removeItem(at: root.appendingPathComponent(folder.name))
            refreshFolders()
            if folders.isEmpty { _ = createFolder("默认目录") }
            return true
        } catch { errorMessage = "删除目录失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult func deleteTrack(_ track: PhoneTrack) -> Bool {
        guard canChange([track]) else { return false }
        do { try fileManager.removeItem(at: track.url); refreshFolders(); return true }
        catch { errorMessage = "删除歌曲失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult func renameTrack(_ track: PhoneTrack, to input: String) -> Bool {
        guard canChange([track]), let name = validatedName(input) else { return false }
        guard let format = AudioFileFormat.format(for: track.url) else { return false }
        let destination = track.url.deletingLastPathComponent().appendingPathComponent(AudioFileFormat.fileName(stem: name, format: format))
        if destination == track.url { return true }
        guard !fileManager.fileExists(atPath: destination.path) else { errorMessage = "该名称的歌曲已存在。"; return false }
        do { try fileManager.moveItem(at: track.url, to: destination); refreshFolders(); return true }
        catch { errorMessage = "重命名歌曲失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult func moveTrack(_ track: PhoneTrack, to folder: PhoneFolder) -> Bool {
        guard canChange([track]) else { return false }
        if track.folder == folder.name { return true }
        let directory = root.appendingPathComponent(folder.name, isDirectory: true)
        let destination = directory.appendingPathComponent(track.fileName)
        guard !fileManager.fileExists(atPath: destination.path) else { errorMessage = "目标目录中存在同名歌曲，请先重命名。"; return false }
        do { try fileManager.moveItem(at: track.url, to: destination); refreshFolders(); return true }
        catch { errorMessage = "移动歌曲失败：\(error.localizedDescription)"; return false }
    }

    private func hasOutstandingTransfer(for track: PhoneTrack) -> Bool {
        if transfers.contains(where: { $0.method == .localNetwork && $0.folder == track.folder && $0.fileName == track.fileName && lanRecordIDs.contains($0.id) }) { return true }
        guard WCSession.isSupported() else { return false }
        return WCSession.default.outstandingFileTransfers.contains {
            let metadata = $0.file.metadata ?? [:]
            return metadata["folder"] as? String == track.folder &&
                metadata["fileName"] as? String == track.fileName
        }
    }

    private func canChange(_ tracks: [PhoneTrack]) -> Bool {
        guard !isImporting else { errorMessage = "正在导入文件，请完成后再修改目录。"; return false }
        guard !tracks.contains(where: hasOutstandingTransfer) else { errorMessage = "歌曲仍有未完成的传输，请先清除任务或等待完成。"; return false }
        return true
    }

    func importFiles(_ urls: [URL], into folder: PhoneFolder) {
        guard !isImporting else { return }
        isImporting = true
        importProgress = 0
        importMessage = "正在准备…"
        importSummary = nil
        let directory = root.appendingPathComponent(folder.name, isDirectory: true)
        Task {
            var songCount = 0
            var failures: [String] = []
            for (index, source) in urls.enumerated() {
                importMessage = source.lastPathComponent
                if AudioFileFormat.supports(source) {
                    let result = await Task.detached(priority: .userInitiated) {
                        Result { try PhoneResourceImport.audio(source, into: directory) }
                    }.value
                    switch result {
                    case .success: songCount += 1
                    case .failure(let error): failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
                    }
                } else { failures.append("\(source.lastPathComponent)：请选择 MP3 或 FLAC") }
                importProgress = Double(index + 1) / Double(max(urls.count, 1))
            }
            isImporting = false
            importMessage = ""
            importProgress = 1
            importSummary = "已导入 \(songCount) 首"
            refreshFolders()
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    func send(_ tracks: [PhoneTrack], retryPending: Bool = false, completion: ((Set<String>) -> Void)? = nil) {
        guard !isImporting else { errorMessage = "导入完成后再发送。"; completion?([]); return }
        guard !tracks.isEmpty, transferSessionReady() else { completion?([]); return }
        guard !isLANActive, !isUpdatingTransferControls else { errorMessage = "请先完成或清除当前任务。"; completion?([]); return }
        startAfterClearingStaleSession(tracks, retryPending: retryPending, completion: completion)
    }

    private func transferSessionReady() -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return false }
        #endif
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { errorMessage = "Apple Watch 连接尚未就绪，请稍后重试。"; return false }
        guard WCSession.default.isPaired else { errorMessage = "请先在 iPhone 上配对 Apple Watch。"; return false }
        guard WCSession.default.isWatchAppInstalled else { errorMessage = "请先在 Apple Watch 上安装“随身音乐 Lab”。"; return false }
        return true
    }

    func cancel(_ record: TransferRecord) {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview {
            updateTransfer(id: record.id, state: .cancelled, message: "已取消")
            return
        }
        #endif
        guard record.state.isPending, WCSession.isSupported() else { return }
        if record.method == .localNetwork {
            lanServer.cancel(fileID: record.id)
            if let sessionID = record.lanSessionID {
                sendLANCommand(LANTransferCommand(sessionID: sessionID, kind: .cancel, fileID: record.id))
            }
            updateTransfer(id: record.id, state: .cancelled, message: "已取消")
            finishLANIfComplete()
            refreshProgress()
            return
        }
        guard record.state == .queued else { return }
        WCSession.default.outstandingFileTransfers.first { $0.file.metadata?["transferID"] as? String == record.id }?.cancel()
        updateTransfer(id: record.id, state: .cancelled, message: "已取消")
        refreshProgress()
    }

    func retry(_ record: TransferRecord) {
        resumeTransfers(ids: [record.id])
    }

    private func controlRecords(ids: Set<String>?) -> [TransferRecord] {
        let records = ids.map { selected in transfers.filter { selected.contains($0.id) } } ?? activeTransfers
        return records.filter { $0.state != .stored && $0.state != .cancelled }
    }

    private func canPause(_ record: TransferRecord) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return record.method == .localNetwork && record.state == .queued }
        #endif
        return record.method == .localNetwork && record.state == .queued && lanRecordIDs.contains(record.id) &&
            (isPreparingLAN || lanHandshakeAccepted)
    }

    private func canStart(_ record: TransferRecord) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return record.state == .paused || record.state == .failed || record.state == .outdated }
        #endif
        if isLANActive {
            return record.method == .localNetwork && record.state == .paused && lanRecordIDs.contains(record.id) &&
                (isPreparingLAN || lanHandshakeAccepted)
        }
        return record.state == .paused || record.state == .failed || record.state == .outdated
    }

    func shouldStartTransfers(ids: Set<String>? = nil) -> Bool {
        !controlRecords(ids: ids).contains(where: canPause)
    }

    func canToggleTransfers(ids: Set<String>? = nil) -> Bool {
        guard !isImporting, !isUpdatingTransferControls else { return false }
        return controlRecords(ids: ids).contains { canPause($0) || canStart($0) }
    }

    func toggleTransfers(ids: Set<String>? = nil) {
        if shouldStartTransfers(ids: ids) { resumeTransfers(ids: ids) }
        else { pauseTransfers(ids: ids) }
    }

    func pauseTransfers(ids: Set<String>? = nil) {
        guard !isUpdatingTransferControls else { return }
        let targets = controlRecords(ids: ids).filter(canPause)
        guard !targets.isEmpty else { return }
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview {
            for record in targets { updateTransfer(id: record.id, state: .paused, message: "已暂停") }
            return
        }
        #endif
        if isPreparingLAN && activeLANSessionID == nil {
            for record in targets { updateTransfer(id: record.id, state: .paused, message: "已暂停") }
            refreshProgress()
            return
        }
        sendTransferControl(paused: true, records: targets)
    }

    func resumeTransfers(ids: Set<String>? = nil) {
        guard !isImporting, !isUpdatingTransferControls else { return }
        let targets = controlRecords(ids: ids).filter(canStart)
        guard !targets.isEmpty else { return }
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview {
            for record in targets { updateTransfer(id: record.id, state: .queued, message: "等待传输") }
            return
        }
        #endif
        if isPreparingLAN && activeLANSessionID == nil {
            for record in targets { updateTransfer(id: record.id, state: .queued, message: "等待传输") }
            refreshProgress()
        } else if isLANActive {
            sendTransferControl(paused: false, records: targets)
        } else {
            restartTransfers(targets)
        }
    }

    /// Cancel the source/remote work before removing its record. Save receipts
    /// for removed IDs are ignored; a file committed before cancellation stays.
    func clearTransfers(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        invalidateTransferControl()
        restartTransferTask?.cancel(); restartTransferTask = nil
        let targets = transfers.filter { ids.contains($0.id) }
        for record in targets where record.state.isPending { cancel(record) }
        for record in targets where record.method == .localNetwork {
            lanServer.cancel(fileID: record.id)
            if let sessionID = record.lanSessionID, record.state.isPending {
                sendLANCommand(LANTransferCommand(sessionID: sessionID, kind: .cancel, fileID: record.id))
            }
        }
        transfers.removeAll { ids.contains($0.id) }
        lanRecordIDs.subtract(ids)
        for id in ids {
            progressSamplers.removeValue(forKey: id)
            transferMetrics.removeValue(forKey: id)
            progress.removeValue(forKey: id)
            lanCompletedBytes.removeValue(forKey: id)
            expectedControlRevisions.removeValue(forKey: id)
        }
        finishLANIfComplete()
        saveTransfers()
        refreshProgress()
    }

    func clearAllTasks() {
        clearTransfers(ids: Set(transfers.filter { $0.state != .stored }.map(\.id)))
    }

    private func invalidateTransferControl() {
        transferControlGeneration = UUID()
        transferControlTask?.cancel(); transferControlTask = nil
        isUpdatingTransferControls = false
        pendingSendCompletion?.finish([])
        pendingSendCompletion = nil
    }

    private func sendTransferControl(paused: Bool, records: [TransferRecord]) {
        guard let sessionID = activeLANSessionID, lanHandshakeAccepted else { return }
        guard isAppForeground, WCSession.default.isReachable else {
            errorMessage = "手表暂不可达，请打开手表 App 后再操作。"
            return
        }
        transferControlRevision += 1
        let revision = transferControlRevision
        let ids = records.map(\.id)
        ids.forEach { expectedControlRevisions[$0] = revision }
        let operation = UUID()
        transferControlGeneration = operation
        isUpdatingTransferControls = true
        let command = LANTransferCommand(sessionID: sessionID, kind: paused ? .pause : .resume,
                                         fileID: nil, fileIDs: ids, controlRevision: revision)
        transferControlTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.requestLANControl(command)
                guard !Task.isCancelled, self.transferControlGeneration == operation,
                      self.activeLANSessionID == sessionID else { return }
                reply.events.forEach { self.handleLANEvent($0) }
                let mismatched = ids.contains { id in
                    guard let record = self.transfers.first(where: { $0.id == id }), record.state.isPending else { return false }
                    return paused ? record.state != .paused && record.state != .awaitingReceipt : record.state == .paused
                }
                if mismatched { self.errorMessage = "部分任务未能完成操作，请连接手表后重试。" }
            } catch {
                guard !Task.isCancelled, self.transferControlGeneration == operation else { return }
                let needsConfirmation = ids.contains { id in
                    guard let record = self.transfers.first(where: { $0.id == id }), record.state.isPending else { return false }
                    return paused ? record.state != .paused && record.state != .awaitingReceipt : record.state == .paused
                }
                if needsConfirmation { self.errorMessage = "未收到手表确认：\(error.localizedDescription)" }
            }
            if self.transferControlGeneration == operation { self.isUpdatingTransferControls = false; self.transferControlTask = nil }
        }
    }

    private func restartTransfers(_ records: [TransferRecord]) {
        let paths = Set(records.map { $0.folder + "/" + $0.fileName })
        let tracks = allTracks.filter { paths.contains($0.id) }
        guard tracks.count == paths.count else { errorMessage = "部分歌曲已被移动或删除，请从音乐库重新选择。"; return }
        guard tracks.count <= 100 else { errorMessage = "单次最多开始 100 首，请分批选择。"; return }
        startAfterClearingStaleSession(tracks, retryPending: true)
    }

    private func startAfterClearingStaleSession(_ tracks: [PhoneTrack], retryPending: Bool,
                                               completion: ((Set<String>) -> Void)? = nil) {
        guard transferSessionReady(), isAppForeground, WCSession.default.isReachable else {
            if errorMessage == nil { errorMessage = "请打开手表 App 后重新开始。" }
            completion?([])
            return
        }
        let operation = UUID()
        transferControlGeneration = operation
        isUpdatingTransferControls = true
        let finished = LANEnqueueCompletion(completion)
        pendingSendCompletion = finished
        restartTransferTask = Task { [weak self] in
            guard let self else { finished.finish([]); return }
            var enqueued = Set<String>()
            defer {
                finished.finish(enqueued)
                if self.pendingSendCompletion === finished { self.pendingSendCompletion = nil }
            }
            do {
                // The source from a previous process/session may have expired,
                // while the watch still owns suspended work. Query read-only,
                // cancel that exact session, then prepare fresh credentials.
                let snapshot = try await self.requestLANControl(LANTransferCommand(sessionID: UUID().uuidString, kind: .status, fileID: nil))
                if let oldSession = snapshot.events.first?.sessionID {
                    _ = try await self.requestLANControl(LANTransferCommand(sessionID: oldSession, kind: .stop, fileID: nil))
                }
                guard !Task.isCancelled, self.transferControlGeneration == operation, !self.isLANActive else { return }
                self.isUpdatingTransferControls = false
                let before = Set(self.transfers.map(\.id))
                self.startLANTransfer(tracks, retryPending: retryPending)
                enqueued = Set(self.transfers.filter { !before.contains($0.id) }.map { $0.folder + "/" + $0.fileName })
            } catch {
                guard !Task.isCancelled, self.transferControlGeneration == operation else { return }
                self.isUpdatingTransferControls = false
                self.errorMessage = "无法重新开始传输：\(error.localizedDescription)"
            }
            if self.transferControlGeneration == operation { self.restartTransferTask = nil }
        }
    }

    private func requestLANControl(_ command: LANTransferCommand) async throws -> LANTransferControlReply {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { throw lanError("手表暂不可达。") }
        let message = try LANTransferWire.message(command, type: LANTransferWire.commandType)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = LANControlReplyGate(continuation)
            gate.timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                gate.finish(.failure(NSError(domain: "LANControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "操作确认超时，请检查手表连接。"])))
            }
            WCSession.default.sendMessage(message, replyHandler: { reply in
                let decoded = LANTransferWire.decode(LANTransferControlReply.self, from: reply, type: LANTransferWire.controlReplyType)
                Task { @MainActor in
                    if let decoded { gate.finish(.success(decoded)) }
                    else { gate.finish(.failure(NSError(domain: "LANControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "请更新手表 App 后再试。"]))) }
                }
            }, errorHandler: { error in
                let detail = error.localizedDescription
                Task { @MainActor in gate.finish(.failure(NSError(domain: "LANControl", code: 3, userInfo: [NSLocalizedDescriptionKey: detail]))) }
            })
        }
    }

    private func refreshTransferControlState() {
        guard let sessionID = activeLANSessionID, lanHandshakeAccepted,
              WCSession.isSupported(), WCSession.default.isReachable, !isUpdatingTransferControls else { return }
        Task { [weak self] in
            guard let self else { return }
            if let reply = try? await self.requestLANControl(LANTransferCommand(sessionID: sessionID, kind: .status, fileID: nil)),
               self.activeLANSessionID == sessionID {
                reply.events.forEach { self.handleLANEvent($0) }
            }
        }
    }

    func clearCompletedTransfers() {
        transfers.removeAll { $0.state == .stored }
        saveTransfers()
        refreshProgress()
    }

    func clearUnfinishedTransfers() {
        var liveIDs = lanRecordIDs
        #if DEBUG && targetEnvironment(simulator)
        if !isTransferListPreview, WCSession.isSupported() {
            liveIDs.formUnion(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?["transferID"] as? String })
        }
        #else
        if WCSession.isSupported() {
            liveIDs.formUnion(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?["transferID"] as? String })
        }
        #endif
        transfers.removeAll { TransferListOrdering.canClearUnfinished($0.state, isLive: liveIDs.contains($0.id)) }
        saveTransfers()
        refreshProgress()
    }

    func latestTransfer(for track: PhoneTrack) -> TransferRecord? {
        transfers.first { $0.folder == track.folder && $0.audioFileName == track.fileName }
    }

    func isFullyTransferred(_ track: PhoneTrack) -> Bool { latestTransfer(for: track)?.state == .stored }

    private func saveTransfers() {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return }
        #endif
        do { try JSONEncoder().encode(transfers).write(to: transferIndex, options: .atomic) }
        catch { errorMessage = "无法保存传输记录：\(error.localizedDescription)" }
    }

    private func updateTransfer(id: String, state: TransferRecord.State, message: String, onlyIfPending: Bool = false) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].state != .stored, transfers[index].state != .cancelled, transfers[index].state != .outdated, !onlyIfPending || transfers[index].state.isPending else { return }
        transfers[index].state = state
        transfers[index].message = message
        if state == .paused {
            progressSamplers.removeValue(forKey: id)
            if let metrics = transferMetrics[id] {
                transferMetrics[id] = TransferMetrics(completedBytes: metrics.completedBytes, totalBytes: metrics.totalBytes,
                                                       bytesPerSecond: nil, estimatedTimeRemaining: nil, isTransferring: false)
            }
        } else if state != .queued {
            progressSamplers.removeValue(forKey: id)
            transferMetrics.removeValue(forKey: id)
            progress.removeValue(forKey: id)
            if !state.isPending { lanCompletedBytes.removeValue(forKey: id) }
        }
        saveTransfers()
    }

    private func refreshProgress() {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return }
        #endif
        let records = Dictionary(uniqueKeysWithValues: transfers.filter { $0.state == .queued || $0.state == .paused }.map { ($0.id, $0) })
        var values: [String: Double] = [:]
        var metrics: [String: TransferMetrics] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        for record in records.values where record.method == .localNetwork && lanRecordIDs.contains(record.id) {
            let completed = min(record.totalBytes, max(0, lanCompletedBytes[record.id] ?? 0))
            values[record.id] = record.totalBytes > 0 ? Double(completed) / Double(record.totalBytes) : 0
            var sampler = progressSamplers[record.id] ?? TransferProgressSampler()
            metrics[record.id] = sampler.sample(completedBytes: completed, totalBytes: record.totalBytes,
                                                isTransferring: record.state == .queued && lanHandshakeAccepted, at: now)
            progressSamplers[record.id] = sampler
        }
        if WCSession.isSupported(), WCSession.default.activationState == .activated {
            for transfer in WCSession.default.outstandingFileTransfers {
                guard let id = transfer.file.metadata?["transferID"] as? String,
                      let record = records[id], record.method == .system else { continue }
                let nativeProgress = transfer.progress
                let totalBytes = max(0, record.totalBytes)
                let fraction = nativeProgress.totalUnitCount > 0 && nativeProgress.fractionCompleted.isFinite
                    ? min(1, max(0, nativeProgress.fractionCompleted)) : 0
                let completedBytes = Int64((Double(totalBytes) * fraction).rounded(.down))
                values[id] = fraction
                var sampler = progressSamplers[id] ?? TransferProgressSampler()
                metrics[id] = sampler.sample(completedBytes: completedBytes, totalBytes: totalBytes,
                                             isTransferring: transfer.isTransferring, at: now)
                progressSamplers[id] = sampler
            }
        }
        progressSamplers = progressSamplers.filter { metrics[$0.key] != nil }
        progress = values
        transferMetrics = metrics
    }

    func sceneDidBecomeActive() { isAppForeground = true }

    func sceneDidEnterBackground() {
        isAppForeground = false
        invalidateTransferControl()
        restartTransferTask?.cancel(); restartTransferTask = nil
        #if DEBUG
        lanProbeWaitTask?.cancel()
        lanProbeWaitTask = nil
        #endif
        stopLANTransfers(message: "手机已进入后台，请保持手机 App 打开后重试。", state: .failed)
    }

    func stopLANTransfers() { stopLANTransfers(message: "已停止局域网传输", state: .cancelled) }

    #if DEBUG && targetEnvironment(simulator)
    /// Isolated screenshot fixtures: startup skips disk access and WC activation,
    /// and all persistence/progress refresh paths remain disabled in this mode.
    func prepareTransferListPreviewIfRequested() {
        guard isTransferListPreview, !didPrepareTransferListPreview else { return }
        didPrepareTransferListPreview = true
        timer?.cancel()
        timer = nil
        let now = Date()
        func record(_ id: String, _ name: String, state: TransferRecord.State,
                    age: TimeInterval, bytes: Int64 = 18_000_000,
                    transport: TransferMethod? = .localNetwork) -> TransferRecord {
            TransferRecord(id: id, folder: "夜跑歌单", fileName: name, createdAt: now.addingTimeInterval(-age),
                           state: state, message: state.title, totalBytes: bytes, transport: transport)
        }
        let active = record("preview-active", "夜空中的旋律.flac", state: .queued, age: 90)
        let waitingOld = record("preview-waiting-old", "海风与落日.mp3", state: .queued, age: 120, bytes: 8_600_000)
        let waitingNew = record("preview-waiting-new", "城市漫步.flac", state: .queued, age: 60, bytes: 26_000_000)
        // Active belongs at the front only through the derived sort. Stored
        // records and waiting records are deliberately reversed in this array.
        transfers = [
            waitingNew,
            record("preview-stored-old", "晴天的远方.mp3", state: .stored, age: 3_600, bytes: 9_200_000, transport: nil),
            waitingOld,
            record("preview-confirming", "山间回声.flac", state: .awaitingReceipt, age: 150, bytes: 21_000_000),
            record("preview-failed", "雨后散步.mp3", state: .failed, age: 300, bytes: 7_400_000),
            record("preview-stored-new", "晚风轻拂.flac", state: .stored, age: 600, bytes: 24_000_000),
            active
        ]
        progress = [active.id: 0.35, waitingOld.id: 0, waitingNew.id: 0]
        transferMetrics = [active.id: TransferMetrics(completedBytes: 6_300_000, totalBytes: active.totalBytes,
                                                      bytesPerSecond: 1_100_000, estimatedTimeRemaining: 10.6,
                                                      isTransferring: true)]
        if ProcessInfo.processInfo.arguments.contains("-preview-transfers-paused") {
            let ids = Set([active.id, waitingOld.id, waitingNew.id])
            for index in transfers.indices where ids.contains(transfers[index].id) {
                transfers[index].state = .paused
                transfers[index].message = "已暂停"
            }
            transferMetrics[active.id] = TransferMetrics(completedBytes: 6_300_000, totalBytes: active.totalBytes,
                                                          bytesPerSecond: nil, estimatedTimeRemaining: nil, isTransferring: false)
        }
        connectionDescription = "Apple Watch 已连接"
    }
    #endif

    #if DEBUG
    /// Starts only a deliberately provisioned fixture folder, never a user's library.
    /// Device validation uses real WCSession messages, HTTP requests, and save receipts.
    func startLANProbeIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !hasRunLANProbe, isAppForeground,
              let flag = arguments.firstIndex(of: "-lan-probe-folder"), arguments.indices.contains(flag + 1) else { return }
        let name = arguments[flag + 1]
        guard name.hasPrefix("LANProbe-"), UUID(uuidString: String(name.dropFirst("LANProbe-".count))) != nil,
              let folder = folders.first(where: { $0.name == name }), !tracks(in: folder).isEmpty else { return }
        hasRunLANProbe = true
        lanProbeWaitTask = Task { [weak self] in
            for _ in 0..<60 {
                guard !Task.isCancelled, let self, self.isAppForeground else { return }
                self.refreshConnection()
                if WCSession.isSupported(), WCSession.default.activationState == .activated,
                   WCSession.default.isReachable, WCSession.default.isPaired, WCSession.default.isWatchAppInstalled {
                    let currentTracks = self.tracks(in: folder)
                    guard !currentTracks.isEmpty, !Task.isCancelled, self.isAppForeground else { return }
                    self.send(currentTracks)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled, let self, self.isAppForeground else { return }
            self.errorMessage = "局域网探针等待手表连接超时。"
        }
    }
    #endif

    private func startLANTransfer(_ tracks: [PhoneTrack], retryPending: Bool) {
        guard isAppForeground else { errorMessage = "请在前台开始局域网传输。"; return }
        guard !isLANActive else { errorMessage = "请先完成或停止当前局域网传输。"; return }
        guard WCSession.default.isReachable else { errorMessage = "请先打开手表 App，再开始局域网传输。"; return }
        var selected: [PhoneTrack] = []
        var seen = Set<String>()
        for track in tracks where seen.insert(track.id).inserted {
            guard fileManager.fileExists(atPath: track.url.path) else { errorMessage = "歌曲已被移动或删除。"; return }
            if let pending = transfers.first(where: { $0.folder == track.folder && $0.fileName == track.fileName && $0.state.isPending }) {
                guard retryPending && !hasOutstandingTransfer(for: track) else { continue }
                updateTransfer(id: pending.id, state: .cancelled, message: "已重新发送")
            }
            selected.append(track)
        }
        guard !selected.isEmpty else { return }
        guard selected.count <= 100 else { errorMessage = "单次局域网传输最多 100 首，请分批发送。"; return }
        let replacing = Set(selected.map(\.id))
        for index in transfers.indices where replacing.contains(transfers[index].folder + "/" + transfers[index].fileName) &&
            (transfers[index].state == .failed || transfers[index].state == .outdated) {
            transfers[index].state = .cancelled
            transfers[index].message = "已重新发送"
        }
        let generation = UUID()
        lanGeneration = generation
        isPreparingLAN = true
        lanHandshakeAccepted = false
        lanStatus = "正在准备局域网传输…"
        savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let sources = selected.map { track -> LANTransferSource in
            let id = UUID().uuidString
            let size = Int64((try? track.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            transfers.insert(TransferRecord(id: id, folder: track.folder, fileName: track.fileName,
                                            createdAt: Date(), state: .queued, message: "正在准备局域网传输",
                                            totalBytes: size, transport: .localNetwork), at: 0)
            lanRecordIDs.insert(id)
            lanCompletedBytes[id] = 0
            return LANTransferSource(id: id, folder: track.folder, fileName: track.fileName, url: track.url)
        }
        saveTransfers()
        refreshProgress()
        lanPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.lanServer.start(sources: sources)
                guard self.lanGeneration == generation, self.isAppForeground, !Task.isCancelled else {
                    if self.lanServer.activeSessionID == prepared.sessionID { self.lanServer.stop() }
                    return
                }
                let pendingIDs = Set(self.transfers.filter { self.lanRecordIDs.contains($0.id) && $0.state.isPending }.map(\.id))
                for file in prepared.files where !pendingIDs.contains(file.id) { self.lanServer.cancel(fileID: file.id) }
                let offer = LANTransferOffer(sessionID: prepared.sessionID, token: prepared.token,
                                             baseURLs: prepared.baseURLs, expiresAt: prepared.expiresAt,
                                             files: prepared.files.filter { pendingIDs.contains($0.id) },
                                             pausedFileIDs: self.transfers.filter { self.lanRecordIDs.contains($0.id) && $0.state == .paused }.map(\.id))
                try LANTransferValidation.validate(offer)
                let message = try LANTransferWire.message(offer, type: LANTransferWire.offerType)
                guard let encoded = message["payload"] as? Data, encoded.count <= 55_000 else {
                    throw self.lanError("传输清单过长，请减少单次发送的歌曲数量。")
                }
                self.activeLANSessionID = offer.sessionID
                self.isPreparingLAN = false
                self.lanStatus = "等待手表接收…"
                for file in offer.files {
                    if let index = self.transfers.firstIndex(where: { $0.id == file.id }) {
                        self.transfers[index].lanSessionID = offer.sessionID
                        self.transfers[index].totalBytes = file.byteCount
                        self.transfers[index].message = "等待手表接收"
                    }
                }
                self.saveTransfers()
                guard WCSession.default.isReachable else { throw self.lanError("手表暂不可达，请打开手表 App 后重试。") }
                self.lanHandshakeTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled, let self, self.lanGeneration == generation,
                          self.activeLANSessionID == offer.sessionID, !self.lanHandshakeAccepted else { return }
                    self.stopLANTransfers(message: "手表未确认接收，请保持两端 App 打开后重试。", state: .failed)
                }
                WCSession.default.sendMessage(message, replyHandler: { [weak self] reply in
                    let accepted = reply["accepted"] as? Bool == true
                    let detail = reply["message"] as? String
                    Task { @MainActor [weak self] in
                        guard let self, self.lanGeneration == generation, self.activeLANSessionID == offer.sessionID else { return }
                        if accepted {
                            self.lanHandshakeAccepted = true
                            self.lanHandshakeTimeout?.cancel()
                            self.lanStatus = "局域网传输中"
                            self.refreshProgress()
                        } else {
                            self.stopLANTransfers(message: detail ?? "手表未能接收局域网传输。", state: .failed)
                        }
                    }
                }, errorHandler: { [weak self] error in
                    let detail = error.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.lanGeneration == generation,
                              self.activeLANSessionID == offer.sessionID, !self.lanHandshakeAccepted else { return }
                        self.stopLANTransfers(message: "无法通知手表：\(detail)", state: .failed)
                    }
                })
            } catch {
                guard self.lanGeneration == generation else { return }
                self.stopLANTransfers(message: error.localizedDescription, state: .failed)
            }
        }
    }

    private func stopLANTransfers(message: String, state: TransferRecord.State, notifyWatch: Bool = true) {
        guard isLANActive || !lanRecordIDs.isEmpty else { return }
        let sessionID = activeLANSessionID
        let ids = lanRecordIDs
        closeLANSession()
        if notifyWatch, let sessionID { sendLANCommand(LANTransferCommand(sessionID: sessionID, kind: .stop, fileID: nil)) }
        for id in ids { updateTransfer(id: id, state: state, message: message, onlyIfPending: true) }
        lanStatus = message
        refreshProgress()
    }

    private func closeLANSession() {
        invalidateTransferControl()
        expectedControlRevisions.removeAll()
        lanGeneration = UUID()
        lanPreparationTask?.cancel()
        lanPreparationTask = nil
        lanHandshakeTimeout?.cancel()
        lanHandshakeTimeout = nil
        lanServer.stop()
        activeLANSessionID = nil
        isPreparingLAN = false
        lanHandshakeAccepted = false
        lanRecordIDs.removeAll()
        lanCompletedBytes.removeAll()
        if let previous = savedIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            savedIdleTimerDisabled = nil
        }
    }

    private func finishLANIfComplete() {
        guard !lanRecordIDs.isEmpty,
              !transfers.contains(where: { lanRecordIDs.contains($0.id) && $0.state.isPending }) else { return }
        let allStored = transfers.filter { lanRecordIDs.contains($0.id) }.allSatisfy { $0.state == .stored }
        closeLANSession()
        lanStatus = allStored ? "局域网传输完成" : "局域网传输已结束"
    }

    private func sendLANCommand(_ command: LANTransferCommand) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let message = try? LANTransferWire.message(command, type: LANTransferWire.commandType) else { return }
        if WCSession.default.isReachable { WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil) }
        // Idempotent commands also reach the watch after a temporary interruption.
        WCSession.default.transferUserInfo(message)
    }

    private func handleLANEvent(_ event: LANTransferEvent) {
        guard let record = transfers.first(where: { $0.id == event.fileID }),
              record.method == .localNetwork, record.lanSessionID == event.sessionID,
              event.totalBytes == record.totalBytes, event.totalBytes > 0,
              event.completedBytes >= 0, event.completedBytes <= event.totalBytes else { return }
        let belongsToActiveSession = activeLANSessionID == event.sessionID && lanRecordIDs.contains(event.fileID)
        // A real bound event can arrive before the asynchronous offer reply.
        if LANReceiptPolicy.confirmsActiveSession(event, recordID: record.id,
                                                   sessionID: record.lanSessionID,
                                                   totalBytes: record.totalBytes, state: record.state,
                                                   belongsToActiveSession: belongsToActiveSession) {
            confirmLANHandshake()
        }
        if event.kind == .stored {
            guard LANReceiptPolicy.acceptsStored(event, recordID: record.id,
                                                 sessionID: record.lanSessionID,
                                                 totalBytes: record.totalBytes, state: record.state) else { return }
            applyVerifiedLANStoredReceipt(event)
            if belongsToActiveSession {
                lanServer.cancel(fileID: event.fileID)
                finishLANIfComplete()
            }
            refreshProgress()
            return
        }
        guard belongsToActiveSession, record.state.isPending else { return }
        switch event.kind {
        case .progress:
            guard record.state == .queued, event.completedBytes >= (lanCompletedBytes[event.fileID] ?? 0) else { return }
            lanCompletedBytes[event.fileID] = event.completedBytes
            lanStatus = "局域网传输中"
            if event.completedBytes == event.totalBytes {
                updateTransfer(id: event.fileID, state: .awaitingReceipt, message: "手表正在校验和保存", onlyIfPending: true)
            }
        case .stored: break
        case .paused, .resumed:
            if let expected = expectedControlRevisions[event.fileID], event.controlRevision != expected { return }
            lanCompletedBytes[event.fileID] = event.completedBytes
            updateTransfer(id: event.fileID,
                           state: event.kind == .paused ? .paused : (event.completedBytes == event.totalBytes ? .awaitingReceipt : .queued),
                           message: event.kind == .paused ? "已暂停" : "继续传输", onlyIfPending: true)
        case .failed:
            updateTransfer(id: event.fileID, state: .failed, message: event.message ?? "局域网接收失败", onlyIfPending: true)
            lanServer.cancel(fileID: event.fileID)
        case .cancelled:
            updateTransfer(id: event.fileID, state: .cancelled, message: event.message ?? "已取消", onlyIfPending: true)
            lanServer.cancel(fileID: event.fileID)
        }
        finishLANIfComplete()
        refreshProgress()
    }

    private func confirmLANHandshake() {
        lanHandshakeAccepted = true
        lanHandshakeTimeout?.cancel()
        lanHandshakeTimeout = nil
    }

    /// A verified save fact can win a race with an earlier local cancel request.
    /// This path deliberately bypasses the generic terminal-state update guard.
    private func applyVerifiedLANStoredReceipt(_ event: LANTransferEvent) {
        guard let index = transfers.firstIndex(where: { $0.id == event.fileID }),
              transfers[index].method == .localNetwork,
              LANReceiptPolicy.acceptsStored(event, recordID: transfers[index].id,
                                              sessionID: transfers[index].lanSessionID,
                                              totalBytes: transfers[index].totalBytes,
                                              state: transfers[index].state) else { return }
        transfers[index].state = .stored
        transfers[index].message = event.message ?? "已保存到手表"
        progressSamplers.removeValue(forKey: event.fileID)
        transferMetrics.removeValue(forKey: event.fileID)
        progress.removeValue(forKey: event.fileID)
        lanCompletedBytes.removeValue(forKey: event.fileID)
        saveTransfers()
    }

    private func lanError(_ message: String) -> NSError {
        NSError(domain: "PhoneLANTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func refreshConnection() {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return }
        #endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        canSend = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
        if session.activationState != .activated { connectionDescription = "正在连接 Apple Watch…" }
        else if !session.isPaired { connectionDescription = "尚未配对 Apple Watch" }
        else if !session.isWatchAppInstalled { connectionDescription = "请在手表上安装 App" }
        else { connectionDescription = session.isReachable ? "Apple Watch 已连接" : "Apple Watch 已配对 · 支持后台传输" }
        refreshProgress()
    }

    private func reconcileTransfers() {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return }
        #endif
        let outstandingIDs = Set(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?["transferID"] as? String })
        for index in transfers.indices where transfers[index].method == .system && transfers[index].state == .queued && !outstandingIDs.contains(transfers[index].id) {
            // Completion callbacks and save receipts can arrive after activation.
            // A missing queue entry alone proves neither delivery nor failure.
            transfers[index].state = .awaitingReceipt
            transfers[index].message = "正在确认传输结果"
        }
        saveTransfers()
        refreshProgress()
    }
}

extension PhoneLibrary: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.refreshConnection()
            if activationState == .activated { self.reconcileTransfers(); self.refreshTransferControlState() }
            if let error { self.errorMessage = "连接手表失败：\(error.localizedDescription)" }
            PlaybackControlCenter.shared.connectionDidChange()
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async { self.refreshConnection(); PlaybackControlCenter.shared.connectionDidChange() }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        DispatchQueue.main.async { PlaybackControlCenter.shared.connectionDidChange() }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.refreshConnection(); PlaybackControlCenter.shared.connectionDidChange() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshConnection(); self.refreshTransferControlState()
            PlaybackControlCenter.shared.connectionDidChange()
        }
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?["transferID"] as? String else { return }
        DispatchQueue.main.async {
            guard self.transfers.first(where: { $0.id == id })?.method == .system else { return }
            if let error { self.updateTransfer(id: id, state: .failed, message: "传输失败：\(error.localizedDescription)", onlyIfPending: true) }
            else { self.updateTransfer(id: id, state: .awaitingReceipt, message: "等待手表保存确认", onlyIfPending: true) }
            self.refreshProgress()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            if PlaybackControlCenter.shared.handle(message) { return }
            guard let event = LANTransferWire.decode(LANTransferEvent.self, from: message, type: LANTransferWire.eventType) else { return }
            self?.handleLANEvent(event)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor [weak self] in
            if PlaybackControlCenter.shared.handle(message, reply: replyHandler) { return }
            if let event = LANTransferWire.decode(LANTransferEvent.self, from: message, type: LANTransferWire.eventType) {
                self?.handleLANEvent(event); replyHandler(["accepted": true])
            } else { replyHandler(["accepted": false]) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let event = LANTransferWire.decode(LANTransferEvent.self, from: userInfo, type: LANTransferWire.eventType) {
            Task { @MainActor [weak self] in self?.handleLANEvent(event) }
            return
        }
        guard userInfo["type"] as? String == "receipt", let id = userInfo["transferID"] as? String, let success = userInfo["success"] as? Bool else { return }
        let message = userInfo["message"] as? String ?? (success ? "已保存到手表" : "手表保存失败")
        DispatchQueue.main.async {
            guard self.transfers.first(where: { $0.id == id })?.method == .system else { return }
            self.updateTransfer(id: id, state: success ? .stored : .failed, message: message)
            self.refreshProgress()
        }
    }
}

@MainActor
private final class LANControlReplyGate {
    private var continuation: CheckedContinuation<LANTransferControlReply, Error>?
    var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<LANTransferControlReply, Error>) { self.continuation = continuation }

    func finish(_ result: Result<LANTransferControlReply, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class LANEnqueueCompletion {
    private var completion: ((Set<String>) -> Void)?
    init(_ completion: ((Set<String>) -> Void)?) { self.completion = completion }
    func finish(_ ids: Set<String>) {
        let callback = completion
        completion = nil
        callback?(ids)
    }
}
