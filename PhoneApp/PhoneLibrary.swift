import AVFoundation
import Combine
import Foundation
import WatchConnectivity

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

struct TransferRecord: Identifiable, Codable {
    enum State: String, Codable {
        case queued, awaitingReceipt, stored, failed, cancelled, outdated
        var title: String {
            switch self {
            case .queued: return "等待传输"
            case .awaitingReceipt: return "等待手表确认"
            case .stored: return "已保存到手表"
            case .failed: return "传输失败"
            case .cancelled: return "已取消"
            case .outdated: return "本地已更新，需重新发送"
            }
        }
        var symbol: String {
            switch self {
            case .queued: return "arrow.up.circle.fill"
            case .awaitingReceipt: return "clock.fill"
            case .stored: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.circle.fill"
            case .cancelled: return "xmark.circle.fill"
            case .outdated: return "arrow.triangle.2.circlepath"
            }
        }
        var isPending: Bool { self == .queued || self == .awaitingReceipt }
    }
    let id: String
    let folder: String
    let fileName: String
    let createdAt: Date
    var state: State
    var message: String
    var totalBytes: Int64 = 0
    var audioFileName: String { fileName }
    var songTitle: String { (fileName as NSString).deletingPathExtension }

}

@MainActor
final class PhoneLibrary: NSObject, ObservableObject {
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
        guard transferSessionReady() else { return }
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
            guard retryPending && !outstanding else { return }
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
        guard record.state == .queued, WCSession.isSupported() else { return }
        WCSession.default.outstandingFileTransfers.first { $0.file.metadata?["transferID"] as? String == record.id }?.cancel()
        updateTransfer(id: record.id, state: .cancelled, message: "已取消")
        refreshProgress()
    }

    func retry(_ record: TransferRecord) {
        guard !isImporting, transferSessionReady() else { return }
        guard let track = allTracks.first(where: { $0.folder == record.folder && $0.fileName == record.audioFileName }) else { errorMessage = "本地文件已被移动或删除，请从音乐库重新发送。"; return }
        queueTransfer(track: track, retryPending: true)
        refreshProgress()
    }

    func clearCompletedTransfers() {
        transfers.removeAll { !$0.state.isPending }
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
        }
        saveTransfers()
    }

    private func refreshProgress() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            progress = [:]
            transferMetrics = [:]
            progressSamplers = [:]
            return
        }
        let records = Dictionary(uniqueKeysWithValues: transfers.filter { $0.state == .queued }.map { ($0.id, $0) })
        var values: [String: Double] = [:]
        var metrics: [String: TransferMetrics] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        for transfer in WCSession.default.outstandingFileTransfers {
            guard let id = transfer.file.metadata?["transferID"] as? String, let record = records[id] else { continue }
            let nativeProgress = transfer.progress
            let totalBytes = max(0, record.totalBytes)
            // Progress does not promise byte units. Normalize its native fraction
            // to the known file length instead of treating unit counts as bytes.
            let fraction = nativeProgress.totalUnitCount > 0 && nativeProgress.fractionCompleted.isFinite
                ? min(1, max(0, nativeProgress.fractionCompleted)) : 0
            let completedBytes = Int64((Double(totalBytes) * fraction).rounded(.down))
            values[id] = fraction
            var sampler = progressSamplers[id] ?? TransferProgressSampler()
            metrics[id] = sampler.sample(completedBytes: completedBytes, totalBytes: totalBytes,
                                         isTransferring: transfer.isTransferring, at: now)
            progressSamplers[id] = sampler
        }
        progressSamplers = progressSamplers.filter { metrics[$0.key] != nil }
        progress = values
        transferMetrics = metrics
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
        for index in transfers.indices where transfers[index].state == .queued && !outstandingIDs.contains(transfers[index].id) {
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
            if let error { self.updateTransfer(id: id, state: .failed, message: "传输失败：\(error.localizedDescription)", onlyIfPending: true) }
            else { self.updateTransfer(id: id, state: .awaitingReceipt, message: "等待手表保存确认", onlyIfPending: true) }
            self.refreshProgress()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["type"] as? String == "receipt", let id = userInfo["transferID"] as? String, let success = userInfo["success"] as? Bool else { return }
        let message = userInfo["message"] as? String ?? (success ? "已保存到手表" : "手表保存失败")
        DispatchQueue.main.async {
            self.updateTransfer(id: id, state: success ? .stored : .failed, message: message)
            self.refreshProgress()
        }
    }
}
