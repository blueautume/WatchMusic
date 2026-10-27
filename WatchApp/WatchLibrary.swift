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
    @Published private(set) var lastTransferMessage: String?
    @Published private(set) var lastReceivedAt: Date?
    @Published var errorMessage: String?
    var allTracks: [URL] { folders.flatMap(\.tracks) }
    var trackCount: Int { allTracks.count }

    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.offlinewatchplayer.lab.watch-library", qos: .utility)
    private let receiveLock = NSLock()
    private var receivingCount = 0
    private let rootURL: URL
    private var session: WCSession?
    private var activationFinished = false
    private var pendingTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var pendingObservation: NSKeyValueObservation?

    override init() {
        rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music", isDirectory: true)
        super.init()
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
            do { try action(); self.refresh(); DispatchQueue.main.async { completion(true) } }
            catch { DispatchQueue.main.async { self.errorMessage = "操作失败：\(error.localizedDescription)"; completion(false) } }
        }
    }

    func addBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        DispatchQueue.main.async { self.pendingTasks.append(task); self.completeBackgroundTasksIfPossible() }
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
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\\"), !trimmed.hasPrefix("."), trimmed.utf8.count <= 240 else { return nil }
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
            self.completeBackgroundTasksIfPossible()
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) { DispatchQueue.main.async { self.updateConnectionStatus() } }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        receiveLock.lock(); receivingCount += 1; receiveLock.unlock()
        DispatchQueue.main.async { self.isReceiving = true }
        let metadata = file.metadata ?? [:]
        let transferID = metadata["transferID"] as? String ?? ""
        var receipt: [String: Any] = ["type": "receipt", "transferID": transferID]
        do {
            try ioQueue.sync {
                guard !transferID.isEmpty, let rawFolder = metadata["folder"] as? String, let folder = safeComponent(rawFolder) else { throw libraryError("目录名或传输标识无效") }
                guard (metadata["kind"] as? String ?? "audio") == "audio" else { throw libraryError("仅支持音频文件") }
                guard let rawName = metadata["fileName"] as? String, let trackName = safeComponent(rawName) else { throw libraryError("歌曲文件名无效") }
                guard AudioFileFormat.supports(URL(fileURLWithPath: trackName)) else { throw libraryError("不支持的歌曲格式") }
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                let values = try file.fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                let size = Int64(values.fileSize ?? 0)
                guard values.isRegularFile == true, size > 0 else { throw libraryError("接收的文件为空或不可读取") }
                let free = freeSpace()
                if free > 0, free < size + 5 * 1_024 * 1_024 { throw libraryError("手表空间不足，请先删除一些歌曲") }
                let directory = rootURL.appendingPathComponent(folder, isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(trackName)
                let probe = try AVAudioPlayer(contentsOf: file.fileURL)
                guard probe.duration.isFinite, probe.duration > 0 else { throw libraryError("文件不是手表可解码的 MP3 或 FLAC") }
                let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
                defer { try? fileManager.removeItem(at: staging) }
                try fileManager.copyItem(at: file.fileURL, to: staging)
                if fileManager.fileExists(atPath: destination.path) { _ = try fileManager.replaceItemAt(destination, withItemAt: staging) }
                else { try fileManager.moveItem(at: staging, to: destination) }
                try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                receipt["success"] = true; receipt["message"] = "歌曲已保存到手表"
                DispatchQueue.main.async {
                    self.lastTransferMessage = "已收到：\((trackName as NSString).deletingPathExtension)"
                    self.lastReceivedAt = Date()
                }
            }
            refresh()
        } catch {
            receipt["success"] = false; receipt["message"] = error.localizedDescription
            DispatchQueue.main.async { self.lastTransferMessage = "接收失败"; self.errorMessage = "保存文件失败：\(error.localizedDescription)" }
        }
        if !transferID.isEmpty, session.activationState == .activated { session.transferUserInfo(receipt) }
        receiveLock.lock(); receivingCount -= 1; let remains = receivingCount > 0; receiveLock.unlock()
        DispatchQueue.main.async { self.isReceiving = remains; self.completeBackgroundTasksIfPossible() }
    }
    private func libraryError(_ message: String) -> NSError { NSError(domain: "WatchLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
