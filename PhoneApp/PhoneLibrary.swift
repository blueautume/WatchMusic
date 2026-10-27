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
    case system, localNetwork
    var id: String { rawValue }
    var title: String { self == .system ? "普通" : "局域网" }
}

struct TransferRecord: Identifiable, Codable {
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
    @Published var transferMethod: TransferMethod = .system
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
    #if DEBUG
    private var hasRunLANProbe = false
    private var lanProbeWaitTask: Task<Void, Never>?
    #endif
    private lazy var lanServer: LANHTTPServer = {
        let server = LANHTTPServer()
        server.onStopped = { [weak self] message in
            self?.stopLANTransfers(message: message, state: .failed)
        }
        return server
    }()

    var isLANActive: Bool { isPreparingLAN || activeLANSessionID != nil }
    var isAwaitingLANAcceptance: Bool { activeLANSessionID != nil && !lanHandshakeAccepted }

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
        guard !tracks.contains(where: hasOutstandingTransfer) else { errorMessage = "歌曲正在传输，请先取消或等待传输完成。"; return false }
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

    func send(_ tracks: [PhoneTrack], retryPending: Bool = false) {
        guard !isImporting else { errorMessage = "导入完成后再发送。"; return }
        guard !tracks.isEmpty, transferSessionReady() else { return }
        if transferMethod == .localNetwork {
            startLANTransfer(tracks, retryPending: retryPending)
            return
        }
        for track in tracks {
            queueTransfer(track: track, retryPending: retryPending)
        }
        refreshProgress()
    }

    private func transferSessionReady() -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { errorMessage = "Apple Watch 连接尚未就绪，请稍后重试。"; return false }
        guard WCSession.default.isPaired else { errorMessage = "请先在 iPhone 上配对 Apple Watch。"; return false }
        guard WCSession.default.isWatchAppInstalled else { errorMessage = "请先在 Apple Watch 上安装“随身音乐 Lab”。"; return false }
        return true
    }

    private func queueTransfer(track: PhoneTrack, retryPending: Bool) {
        let session = WCSession.default
        guard fileManager.fileExists(atPath: track.url.path) else { errorMessage = "歌曲已被移动或删除。"; return }
        if let pending = transfers.first(where: { $0.folder == track.folder && $0.fileName == track.fileName && $0.state.isPending }) {
            let outstanding = session.outstandingFileTransfers.contains { $0.file.metadata?["transferID"] as? String == pending.id }
            let localTransferIsLive = pending.method == .localNetwork && lanRecordIDs.contains(pending.id)
            guard retryPending && !outstanding && !localTransferIsLive else { return }
            updateTransfer(id: pending.id, state: .cancelled, message: "已重新发送")
        }
        let bytes = Int64((try? track.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let record = TransferRecord(id: UUID().uuidString, folder: track.folder, fileName: track.fileName, createdAt: Date(), state: .queued, message: "等待系统安排传输", totalBytes: bytes)
        let metadata: [String: Any] = ["transferID": record.id, "folder": track.folder, "fileName": track.fileName, "kind": "audio"]
        transfers.insert(record, at: 0)
        saveTransfers()
        session.transferFile(track.url, metadata: metadata)
    }

    func cancel(_ record: TransferRecord) {
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

    func retry(_ record: TransferRecord, using method: TransferMethod? = nil) {
        guard !isImporting, transferSessionReady() else { return }
        guard let track = allTracks.first(where: { $0.folder == record.folder && $0.fileName == record.audioFileName }) else { errorMessage = "本地文件已被移动或删除，请从音乐库重新发送。"; return }
        if (method ?? record.method) == .localNetwork { startLANTransfer([track], retryPending: true) }
        else { queueTransfer(track: track, retryPending: true); refreshProgress() }
    }

    func clearCompletedTransfers() {
        transfers.removeAll { !$0.state.isPending && !lanRecordIDs.contains($0.id) }
        saveTransfers()
        refreshProgress()
    }

    func latestTransfer(for track: PhoneTrack) -> TransferRecord? {
        transfers.first { $0.folder == track.folder && $0.audioFileName == track.fileName }
    }

    func isFullyTransferred(_ track: PhoneTrack) -> Bool { latestTransfer(for: track)?.state == .stored }

    private func saveTransfers() {
        do { try JSONEncoder().encode(transfers).write(to: transferIndex, options: .atomic) }
        catch { errorMessage = "无法保存传输记录：\(error.localizedDescription)" }
    }

    private func updateTransfer(id: String, state: TransferRecord.State, message: String, onlyIfPending: Bool = false) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].state != .stored, transfers[index].state != .cancelled, transfers[index].state != .outdated, !onlyIfPending || transfers[index].state.isPending else { return }
        transfers[index].state = state
        transfers[index].message = message
        if state != .queued {
            progressSamplers.removeValue(forKey: id)
            transferMetrics.removeValue(forKey: id)
            progress.removeValue(forKey: id)
            if !state.isPending { lanCompletedBytes.removeValue(forKey: id) }
        }
        saveTransfers()
    }

    private func refreshProgress() {
        let records = Dictionary(uniqueKeysWithValues: transfers.filter { $0.state == .queued }.map { ($0.id, $0) })
        var values: [String: Double] = [:]
        var metrics: [String: TransferMetrics] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        for record in records.values where record.method == .localNetwork && lanRecordIDs.contains(record.id) {
            let completed = min(record.totalBytes, max(0, lanCompletedBytes[record.id] ?? 0))
            values[record.id] = record.totalBytes > 0 ? Double(completed) / Double(record.totalBytes) : 0
            var sampler = progressSamplers[record.id] ?? TransferProgressSampler()
            metrics[record.id] = sampler.sample(completedBytes: completed, totalBytes: record.totalBytes,
                                                isTransferring: lanHandshakeAccepted, at: now)
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
        #if DEBUG
        lanProbeWaitTask?.cancel()
        lanProbeWaitTask = nil
        #endif
        stopLANTransfers(message: "手机已进入后台，请保持两端 App 打开后重试。", state: .failed)
    }

    func stopLANTransfers() { stopLANTransfers(message: "已停止局域网传输", state: .cancelled) }

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
                    self.transferMethod = .localNetwork
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
                                             files: prepared.files.filter { pendingIDs.contains($0.id) })
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

    private func stopLANTransfers(message: String, state: TransferRecord.State) {
        guard isLANActive || !lanRecordIDs.isEmpty else { return }
        let sessionID = activeLANSessionID
        let ids = lanRecordIDs
        closeLANSession()
        if let sessionID { sendLANCommand(LANTransferCommand(sessionID: sessionID, kind: .stop, fileID: nil)) }
        for id in ids { updateTransfer(id: id, state: state, message: message, onlyIfPending: true) }
        lanStatus = message
        refreshProgress()
    }

    private func closeLANSession() {
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
        DispatchQueue.main.async { self.refreshConnection(); if activationState == .activated { self.reconcileTransfers() }; if let error { self.errorMessage = "连接手表失败：\(error.localizedDescription)" } }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { DispatchQueue.main.async { self.refreshConnection() } }
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { DispatchQueue.main.async { self.refreshConnection() } }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { DispatchQueue.main.async { self.refreshConnection() } }
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
        guard let event = LANTransferWire.decode(LANTransferEvent.self, from: message, type: LANTransferWire.eventType) else { return }
        Task { @MainActor [weak self] in self?.handleLANEvent(event) }
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
