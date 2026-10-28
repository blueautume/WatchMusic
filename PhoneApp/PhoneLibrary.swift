import AVFoundation
import Combine
import Foundation
import WatchConnectivity
import UIKit

struct PhoneFolder: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct PhoneTrack: Identifiable, Hashable, Sendable {
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
    var sourceVersion: TransferSourceVersion? = nil
    var sourceSHA256: String? = nil
    var resumesWhenForeground: Bool? = nil
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
    private let queueIndex: URL
    private let continuedProcessing = LANContinuedProcessing.shared
    private var currentLANOrder: [String] = []
    private var backgroundTrackedIDs = Set<String>()
    private var backgroundRuntimeGranted = false
    private var backgroundTransition = false
    private var backgroundTransitionLease: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTransitionTask: Task<Void, Never>?
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
    @Published private(set) var transferSummary: String?
    private var waitingLANIDs: [String] = []
    private var queuedLANSources: [String: PhoneTrack] = [:]
    private var sendSubmissions: [LANSendSubmission] = []
    private var submissionTask: Task<Void, Never>?
    private var submissionGeneration = UUID()
    private var queueMutationDepth = 0
    private var queuePaused = false
    #if DEBUG && targetEnvironment(simulator)
    private var queueProbeRequest: (([String: Any]) async throws -> [String: Any])?
    private var queueProbePersistenceDirectory: URL?
    #endif
    #if DEBUG
    private var hasRunLANProbe = false
    private var lanProbeWaitTask: Task<Void, Never>?
    private var observedPhonePhase = "launching"
    private var lastPhoneProgressLog: TimeInterval = 0
    private var lastPhoneConnectionLog: String?
    #endif
    #if DEBUG && targetEnvironment(simulator)
    private let isTransferListPreview = ProcessInfo.processInfo.arguments.contains("-preview-transfers-in-progress") ||
        ProcessInfo.processInfo.arguments.contains("-preview-transfers-completed")
    private var didPrepareTransferListPreview = false
    #endif
    private lazy var lanServer: LANHTTPServer = {
        let server = LANHTTPServer()
        server.onStopped = { [weak self] message in
            self?.parkLANQueue(message: message, resumeOnForeground: true)
        }
        return server
    }()

    func isCurrentLANTransfer(_ id: String) -> Bool { lanRecordIDs.contains(id) }

    private var canProcessLAN: Bool {
        isAppForeground || continuedProcessing.canRunInBackground || backgroundTransition
    }

    private var watchIsReachable: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if queueProbeRequest != nil { return true }
        #endif
        return WCSession.isSupported() && WCSession.default.isReachable
    }

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
        queueIndex = documents.appendingPathComponent("lan-phone-queue.json")
        super.init()
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview { return }
        #endif
        configureContinuedProcessing()
        continuedProcessing.register()
        recordPhoneLifecycle("runtime-registration")
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("默认目录", isDirectory: true), withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: transferIndex) {
                transfers = (try? JSONDecoder().decode([TransferRecord].self, from: data)) ?? []
            }
            refreshFolders()
            restoreLANQueue()
            saveTransfers()
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
        if sendSubmissions.contains(where: { $0.tracks.contains(where: { $0.id == track.id }) }) { return true }
        if transfers.contains(where: { $0.method == .localNetwork && $0.folder == track.folder && $0.fileName == track.fileName &&
            (lanRecordIDs.contains($0.id) || waitingLANIDs.contains($0.id)) }) { return true }
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
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert(LANInventoryWire.pathKey(folder: $0.folder, fileName: $0.fileName)).inserted }
        sendSubmissions.append(LANSendSubmission(id: UUID(), tracks: unique, completion: LANEnqueueCompletion(completion)))
        beginContinuedProcessingFromUserAction()
        saveTransfers()
        processSendSubmissions()
    }

    private func updateSourceIdleTimer() {
        #if DEBUG && targetEnvironment(simulator)
        if queueProbeRequest != nil { return }
        #endif
        let needsSource = isAppForeground && (isLANActive || submissionTask != nil ||
            waitingLANIDs.contains { id in transfers.first(where: { $0.id == id })?.state == .queued })
        if needsSource, savedIdleTimerDisabled == nil {
            savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !needsSource, let previous = savedIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            savedIdleTimerDisabled = nil
        }
    }

    private func processSendSubmissions() {
        guard submissionTask == nil, !sendSubmissions.isEmpty, canProcessLAN else { return }
        guard watchIsReachable else { transferSummary = "等待手表连接"; return }
        let generation = submissionGeneration
        submissionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.submissionGeneration == generation,
                  self.canProcessLAN, self.watchIsReachable, let submission = self.sendSubmissions.first {
                var handled = Set<String>()
                do {
                    let pendingPaths = Set(self.transfers.filter { $0.state.isPending }.map {
                        LANInventoryWire.pathKey(folder: $0.folder, fileName: $0.fileName)
                    })
                    let candidates = submission.tracks.filter { track in
                        if pendingPaths.contains(LANInventoryWire.pathKey(folder: track.folder, fileName: track.fileName)) {
                            handled.insert(track.id); return false
                        }
                        return true
                    }
                    self.transferSummary = candidates.isEmpty ? "已在队列中" : "正在检查 \(candidates.count) 首"
                    let prepared = try await LANSendPreparation.prepare(candidates)
                    var matched = Set<String>()
                    for offset in stride(from: 0, to: prepared.count, by: LANInventoryWire.maximumFiles) {
                        let files = Array(prepared[offset..<min(prepared.count, offset + LANInventoryWire.maximumFiles)]).map(\.file)
                        let request = LANInventoryRequest(requestID: UUID().uuidString, files: files)
                        let reply = try await self.requestInventory(request)
                        matched.formUnion(reply.matchedFileIDs)
                    }
                    guard !Task.isCancelled, self.submissionGeneration == generation else { break }
                    for candidate in prepared {
                        guard candidate.version == (try TransferSourceVersion.read(candidate.track.url)) else {
                            throw self.lanError("歌曲文件已变化，请重新发送。")
                        }
                    }
                    var added = 0
                    var skipped = handled.count
                    for candidate in prepared {
                        let path = LANInventoryWire.pathKey(folder: candidate.track.folder, fileName: candidate.track.fileName)
                        if self.transfers.contains(where: { $0.state.isPending && LANInventoryWire.pathKey(folder: $0.folder, fileName: $0.fileName) == path }) {
                            skipped += 1
                        } else if matched.contains(candidate.file.id) {
                            self.recordExistingWatchFile(candidate)
                            skipped += 1
                        } else {
                            self.retireReplacedFailures(path: path)
                            self.transfers.insert(TransferRecord(id: candidate.file.id, folder: candidate.file.folder,
                                fileName: candidate.file.fileName, createdAt: Date(), state: self.queuePaused ? .paused : .queued,
                                message: self.queuePaused ? "已暂停" : "等待传输",
                                totalBytes: candidate.file.byteCount, transport: .localNetwork,
                                sourceVersion: candidate.version, sourceSHA256: candidate.file.sha256), at: 0)
                            self.waitingLANIDs.append(candidate.file.id)
                            self.backgroundTrackedIDs.insert(candidate.file.id)
                            self.queuedLANSources[candidate.file.id] = candidate.track
                            added += 1
                        }
                        handled.insert(candidate.track.id)
                    }
                    self.saveTransfers(); self.refreshProgress()
                    self.transferSummary = added == 0 ? "已跳过 \(skipped) 首" : (skipped == 0 ? "已加入 \(added) 首" : "已加入 \(added) 首，跳过 \(skipped) 首")
                    self.startNextLANBatch()
                } catch {
                    if !Task.isCancelled, self.submissionGeneration == generation { self.errorMessage = "检查歌曲失败：\(error.localizedDescription)" }
                }
                submission.completion.finish(handled)
                if self.sendSubmissions.first?.id == submission.id { self.sendSubmissions.removeFirst() }
                self.saveTransfers()
            }
            if self.submissionGeneration == generation { self.submissionTask = nil }
            self.updateSourceIdleTimer()
            self.updateContinuedProcessingProgress()
        }
        updateSourceIdleTimer()
    }

    private func configureContinuedProcessing() {
        continuedProcessing.onGranted = { [weak self] in
            guard let self else { return }
            self.backgroundRuntimeGranted = true
            self.recordPhoneLifecycle("runtime-granted")
            self.endBackgroundTransition()
            self.processSendSubmissions()
            self.startNextLANBatch()
            self.updateContinuedProcessingProgress()
        }
        continuedProcessing.onInterrupted = { [weak self] message in
            guard let self else { return }
            let hadRuntime = self.backgroundRuntimeGranted
            self.backgroundRuntimeGranted = false
            self.recordPhoneLifecycle("runtime-interrupted")
            if !self.isAppForeground || hadRuntime {
                // Expiration also represents cancellation from the system UI.
                // Require an explicit Start so cancellation is respected.
                self.parkLANQueue(message: message, resumeOnForeground: false)
            } else {
                self.transferSummary = "后台传输暂不可用"
            }
        }
    }

    private func beginContinuedProcessingFromUserAction() {
        guard isAppForeground else { return }
        if !continuedProcessing.canRunInBackground && !continuedProcessing.isRequesting {
            backgroundTrackedIDs = Set(transfers.filter { $0.method == .localNetwork && $0.state.isPending }.map(\.id))
        }
        let requested = continuedProcessing.beginFromUserAction(isForeground: true)
        recordPhoneLifecycle(requested ? "runtime-requested" : "runtime-unavailable")
    }

    private func updateContinuedProcessingProgress() {
        let records = transfers.filter { backgroundTrackedIDs.contains($0.id) && $0.state != .cancelled }
        let completedFiles = records.filter { $0.state == .stored }.count
        let completedBytes = records.reduce(Int64(0)) { value, record in
            value + (record.state == .stored ? record.totalBytes : min(record.totalBytes, max(0, lanCompletedBytes[record.id] ?? 0)))
        }
        continuedProcessing.update(completedBytes: completedBytes, totalBytes: records.reduce(0) { $0 + $1.totalBytes },
            completedFiles: completedFiles, totalFiles: records.count,
            subtitle: records.isEmpty ? "正在检查歌曲" : "已完成 \(completedFiles)/\(records.count) 首")
        let current = transfers.filter { lanRecordIDs.contains($0.id) && $0.state.isPending }
        let hasRunnableWork = (!queuePaused && !sendSubmissions.isEmpty) ||
            current.contains { $0.state != .paused } ||
            (!isLANActive && waitingLANIDs.contains { id in transfers.contains { $0.id == id && $0.state == .queued } })
        if !hasRunnableWork, submissionTask == nil, !isUpdatingTransferControls {
            backgroundRuntimeGranted = false
            continuedProcessing.finish(success: records.allSatisfy { $0.state == .stored })
        }
    }

    private var persistedTransferIndex: URL {
        #if DEBUG && targetEnvironment(simulator)
        if let directory = queueProbePersistenceDirectory { return directory.appendingPathComponent("transfers.json") }
        #endif
        return transferIndex
    }

    private var persistedQueueIndex: URL {
        #if DEBUG && targetEnvironment(simulator)
        if let directory = queueProbePersistenceDirectory { return directory.appendingPathComponent("lan-phone-queue.json") }
        #endif
        return queueIndex
    }

    private func queuedTrack(folder: String, fileName: String) -> PhoneTrack? {
        guard LANQueuedTrackLocation(folder: folder, fileName: fileName).isValid else { return nil }
        let url = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(fileName)
        return PhoneTrack(folder: folder, fileName: fileName, url: url)
    }

    private func restoreLANQueue() {
        let snapshot = (try? Data(contentsOf: persistedQueueIndex)).flatMap { try? JSONDecoder().decode(LANPhoneQueueSnapshot.self, from: $0) }
        queuePaused = snapshot?.globallyPaused ?? false
        let records = transfers.filter { $0.method == .localNetwork && $0.state.isPending }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var seen = Set<String>()
        waitingLANIDs = ((snapshot?.orderedRecordIDs ?? []) + records.sorted { $0.createdAt < $1.createdAt }.map(\.id))
            .filter { byID[$0] != nil && seen.insert($0).inserted }
        for id in waitingLANIDs {
            guard let index = transfers.firstIndex(where: { $0.id == id }),
                  let track = queuedTrack(folder: transfers[index].folder, fileName: transfers[index].fileName),
                  let version = transfers[index].sourceVersion, let hash = transfers[index].sourceSHA256,
                  LANInventoryWire.validDigest(hash), (try? TransferSourceVersion.read(track.url)) == version else {
                if let index = transfers.firstIndex(where: { $0.id == id }) {
                    transfers[index].state = .outdated; transfers[index].message = "本地文件已变化，请重新发送"
                }
                continue
            }
            queuedLANSources[id] = track
            if transfers[index].state != .paused {
                transfers[index].resumesWhenForeground = true
                transfers[index].state = .paused
                transfers[index].message = "等待恢复"
            }
        }
        waitingLANIDs.removeAll { queuedLANSources[$0] == nil }
        for locations in snapshot?.submissions ?? [] {
            let tracks = locations.filter(\.isValid).compactMap { queuedTrack(folder: $0.folder, fileName: $0.fileName) }
            if !tracks.isEmpty { sendSubmissions.append(LANSendSubmission(id: UUID(), tracks: tracks, completion: LANEnqueueCompletion(nil))) }
        }
    }

    /// Stop the volatile HTTP session, retaining queue order, source identities,
    /// user pauses and Watch's validated partial files for a fresh session.
    private func parkLANQueue(message: String, resumeOnForeground: Bool) {
        queueMutationDepth += 1
        if !resumeOnForeground { queuePaused = true }
        let order = currentLANOrder + waitingLANIDs
        let sources = queuedLANSources
        let sessionID = activeLANSessionID
        submissionGeneration = UUID()
        submissionTask?.cancel(); submissionTask = nil
        sendSubmissions.forEach { $0.completion.finish([]) }
        closeLANSession()
        waitingLANIDs = order.filter { id in transfers.contains { $0.id == id && $0.state.isPending } }
        queuedLANSources = sources.filter { waitingLANIDs.contains($0.key) }
        for index in transfers.indices where waitingLANIDs.contains(transfers[index].id) && transfers[index].state != .paused {
            transfers[index].state = .paused
            transfers[index].message = message
            transfers[index].resumesWhenForeground = resumeOnForeground
        }
        if let sessionID { sendLANCommand(LANTransferCommand(sessionID: sessionID, kind: .stop, fileID: nil, preservePartialFiles: true)) }
        backgroundRuntimeGranted = false
        continuedProcessing.finish(success: false)
        endBackgroundTransition()
        saveTransfers()
        lanStatus = message
        queueMutationDepth -= 1
        refreshProgress()
        updateSourceIdleTimer()
    }

    private func endBackgroundTransition() {
        backgroundTransition = false
        backgroundTransitionTask?.cancel(); backgroundTransitionTask = nil
        #if DEBUG && targetEnvironment(simulator)
        if queueProbeRequest != nil { return }
        #endif
        if backgroundTransitionLease != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTransitionLease)
            backgroundTransitionLease = .invalid
        }
    }

    private func retireReplacedFailures(path: String) {
        for index in transfers.indices where LANInventoryWire.pathKey(folder: transfers[index].folder, fileName: transfers[index].fileName) == path &&
            (transfers[index].state == .failed || transfers[index].state == .outdated) {
            transfers[index].state = .cancelled; transfers[index].message = "已重新加入队列"
        }
    }

    private func recordExistingWatchFile(_ candidate: LANSendCandidate) {
        let path = LANInventoryWire.pathKey(folder: candidate.file.folder, fileName: candidate.file.fileName)
        retireReplacedFailures(path: path)
        if let index = transfers.firstIndex(where: { $0.state == .stored && LANInventoryWire.pathKey(folder: $0.folder, fileName: $0.fileName) == path }) {
            transfers[index].sourceVersion = candidate.version
            transfers[index].sourceSHA256 = candidate.file.sha256
            transfers[index].totalBytes = candidate.file.byteCount
        } else {
            transfers.insert(TransferRecord(id: candidate.file.id, folder: candidate.file.folder, fileName: candidate.file.fileName,
                createdAt: Date(), state: .stored, message: "已在手表中", totalBytes: candidate.file.byteCount,
                transport: .localNetwork, sourceVersion: candidate.version, sourceSHA256: candidate.file.sha256), at: 0)
        }
    }

    private func cancelSendSubmissions() {
        submissionGeneration = UUID()
        submissionTask?.cancel(); submissionTask = nil
        sendSubmissions.forEach { $0.completion.finish([]) }
        sendSubmissions.removeAll()
        saveTransfers()
        updateSourceIdleTimer()
        updateContinuedProcessingProgress()
    }

    private func transferSessionReady() -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if queueProbeRequest != nil { return true }
        #endif
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
        if isTransferListPreview, queueProbeRequest == nil {
            updateTransfer(id: record.id, state: .cancelled, message: "已取消")
            return
        }
        #endif
        guard record.state.isPending, WCSession.isSupported() else { return }
        if record.method == .localNetwork {
            waitingLANIDs.removeAll { $0 == record.id }
            queuedLANSources.removeValue(forKey: record.id)
            lanServer.cancel(fileID: record.id)
            if let sessionID = record.lanSessionID {
                sendLANCommand(LANTransferCommand(sessionID: sessionID, kind: .cancel, fileID: record.id))
            }
            updateTransfer(id: record.id, state: .cancelled, message: "已取消")
            finishLANIfComplete()
            refreshProgress()
            updateSourceIdleTimer()
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
        if isTransferListPreview, queueProbeRequest == nil { return record.method == .localNetwork && record.state == .queued }
        #endif
        return record.method == .localNetwork && record.state == .queued &&
            (waitingLANIDs.contains(record.id) || (lanRecordIDs.contains(record.id) && (isPreparingLAN || lanHandshakeAccepted)))
    }

    private func canStart(_ record: TransferRecord) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview, queueProbeRequest == nil { return record.state == .paused || record.state == .failed || record.state == .outdated }
        #endif
        if waitingLANIDs.contains(record.id) { return record.state == .paused }
        if lanRecordIDs.contains(record.id), record.state == .paused { return isPreparingLAN || lanHandshakeAccepted }
        return record.state == .paused || record.state == .failed || record.state == .outdated
    }

    func shouldStartTransfers(ids: Set<String>? = nil) -> Bool {
        if ids == nil, isLANActive {
            let current = transfers.filter { lanRecordIDs.contains($0.id) && $0.state.isPending }
            if current.contains(where: { $0.state == .paused }), !current.contains(where: canPause) { return true }
        }
        return !controlRecords(ids: ids).contains(where: canPause)
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
        if ids == nil { queuePaused = true }
        let targets = controlRecords(ids: ids).filter(canPause)
        guard !targets.isEmpty else { return }
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview, queueProbeRequest == nil {
            for record in targets { updateTransfer(id: record.id, state: .paused, message: "已暂停") }
            return
        }
        #endif
        let local = targets.filter { waitingLANIDs.contains($0.id) || (lanRecordIDs.contains($0.id) && activeLANSessionID == nil) }
        for record in local { updateTransfer(id: record.id, state: .paused, message: "已暂停") }
        let localIDs = Set(local.map(\.id))
        let remote = targets.filter { !localIDs.contains($0.id) }
        if !remote.isEmpty { sendTransferControl(paused: true, records: remote) }
        refreshProgress()
        updateSourceIdleTimer()
    }

    func resumeTransfers(ids: Set<String>? = nil) {
        guard !isImporting, !isUpdatingTransferControls else { return }
        queuePaused = false
        let targets = controlRecords(ids: ids).filter(canStart)
        guard !targets.isEmpty else { return }
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview, queueProbeRequest == nil {
            for record in targets { updateTransfer(id: record.id, state: .queued, message: "等待传输") }
            return
        }
        #endif
        var retry: [TransferRecord] = []
        var remote: [TransferRecord] = []
        for record in targets {
            if waitingLANIDs.contains(record.id) || (lanRecordIDs.contains(record.id) && activeLANSessionID == nil && record.state == .paused) {
                updateTransfer(id: record.id, state: .queued, message: "等待传输")
            } else if lanRecordIDs.contains(record.id), record.state == .paused { remote.append(record) }
            else { retry.append(record) }
        }
        if !remote.isEmpty { sendTransferControl(paused: false, records: remote) }
        if !retry.isEmpty { restartTransfers(retry) }
        beginContinuedProcessingFromUserAction()
        startNextLANBatch()
        refreshProgress()
        updateSourceIdleTimer()
    }

    /// Cancel the source/remote work before removing its record. Save receipts
    /// for removed IDs are ignored; a file committed before cancellation stays.
    func clearTransfers(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        queueMutationDepth += 1
        defer { queueMutationDepth -= 1; startNextLANBatch() }
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
        waitingLANIDs.removeAll { ids.contains($0) }
        ids.forEach { queuedLANSources.removeValue(forKey: $0) }
        for id in ids {
            progressSamplers.removeValue(forKey: id)
            transferMetrics.removeValue(forKey: id)
            progress.removeValue(forKey: id)
            lanCompletedBytes.removeValue(forKey: id)
            expectedControlRevisions.removeValue(forKey: id)
        }
        if lanRecordIDs.isEmpty, isLANActive { closeLANSession() }
        else { finishLANIfComplete() }
        saveTransfers()
        refreshProgress()
        updateSourceIdleTimer()
    }

    func clearAllTasks() {
        queuePaused = false
        cancelSendSubmissions()
        transferSummary = nil
        clearTransfers(ids: Set(transfers.filter { $0.state != .stored }.map(\.id)))
    }

    private func invalidateTransferControl() {
        transferControlGeneration = UUID()
        transferControlTask?.cancel(); transferControlTask = nil
        isUpdatingTransferControls = false
    }

    private func sendTransferControl(paused: Bool, records: [TransferRecord]) {
        guard let sessionID = activeLANSessionID, lanHandshakeAccepted else { return }
        guard canProcessLAN, watchIsReachable else {
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
            if self.transferControlGeneration == operation {
                self.isUpdatingTransferControls = false; self.transferControlTask = nil
                self.startNextLANBatch()
            }
        }
    }

    private func restartTransfers(_ records: [TransferRecord]) {
        let tracks = records.map { record in
            let url = root.appendingPathComponent(record.folder, isDirectory: true).appendingPathComponent(record.fileName)
            return PhoneTrack(folder: record.folder, fileName: record.fileName, url: url)
        }
        send(tracks, retryPending: true)
    }

    private func requestInventory(_ request: LANInventoryRequest) async throws -> LANInventoryReply {
        try LANInventoryWire.validate(request)
        let message = try LANTransferWire.message(request, type: LANInventoryWire.requestType)
        let response = try await requestLiveMessage(message)
        guard let reply = LANTransferWire.decode(LANInventoryReply.self, from: response, type: LANInventoryWire.replyType) else {
            throw lanError("请更新手表 App 后再试。")
        }
        try LANInventoryWire.validate(reply, for: request)
        return reply
    }

    private func requestLANControl(_ command: LANTransferCommand) async throws -> LANTransferControlReply {
        let message = try LANTransferWire.message(command, type: LANTransferWire.commandType)
        let response = try await requestLiveMessage(message)
        guard let reply = LANTransferWire.decode(LANTransferControlReply.self, from: response, type: LANTransferWire.controlReplyType) else {
            throw lanError("请更新手表 App 后再试。")
        }
        return reply
    }

    private func requestLiveMessage(_ message: [String: Any]) async throws -> [String: Any] {
        #if DEBUG && targetEnvironment(simulator)
        if let queueProbeRequest { return try await queueProbeRequest(message) }
        #endif
        guard transferSessionReady(), watchIsReachable else { throw lanError("手表暂不可达。") }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = LANMessageReplyGate(continuation)
            gate.timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { return }
                gate.finish(.failure(NSError(domain: "LANControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "操作确认超时，请检查手表连接。"])))
            }
            WCSession.default.sendMessage(message, replyHandler: { reply in
                Task { @MainActor in gate.finish(.success(reply)) }
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
        transfers.first { $0.folder == track.folder && $0.audioFileName == track.fileName && $0.state != .cancelled }
    }

    func isFullyTransferred(_ track: PhoneTrack) -> Bool {
        guard let record = latestTransfer(for: track), record.state == .stored,
              let version = record.sourceVersion, let hash = record.sourceSHA256,
              LANInventoryWire.validDigest(hash) else { return false }
        return (try? TransferSourceVersion.read(track.url)) == version
    }

    private func saveTransfers() {
        #if DEBUG && targetEnvironment(simulator)
        if isTransferListPreview, queueProbePersistenceDirectory == nil { return }
        #endif
        do {
            let snapshot = LANPhoneQueueSnapshot(orderedRecordIDs: currentLANOrder + waitingLANIDs,
                submissions: sendSubmissions.map { $0.tracks.map { LANQueuedTrackLocation(folder: $0.folder, fileName: $0.fileName) } },
                globallyPaused: queuePaused)
            try JSONEncoder().encode(transfers).write(to: persistedTransferIndex, options: .atomic)
            try JSONEncoder().encode(snapshot).write(to: persistedQueueIndex, options: .atomic)
            for url in [persistedTransferIndex, persistedQueueIndex] {
                try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
        }
        catch { errorMessage = "无法保存传输记录：\(error.localizedDescription)" }
    }

    private func updateTransfer(id: String, state: TransferRecord.State, message: String, onlyIfPending: Bool = false) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].state != .stored, transfers[index].state != .cancelled, transfers[index].state != .outdated, !onlyIfPending || transfers[index].state.isPending else { return }
        transfers[index].state = state
        transfers[index].resumesWhenForeground = nil
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
        defer { updateContinuedProcessingProgress() }
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

    func sceneDidBecomeActive() {
        isAppForeground = true
        #if DEBUG
        observedPhonePhase = "active"
        #endif
        recordPhoneLifecycle("scene")
        endBackgroundTransition()
        if !queuePaused {
            for index in transfers.indices where transfers[index].state == .paused && transfers[index].resumesWhenForeground == true {
                transfers[index].state = .queued
                transfers[index].resumesWhenForeground = nil
                transfers[index].message = "等待传输"
            }
        }
        saveTransfers()
        processSendSubmissions()
        startNextLANBatch()
        updateSourceIdleTimer()
    }

    func sceneDidEnterBackground() {
        isAppForeground = false
        #if DEBUG
        observedPhonePhase = "background"
        #endif
        recordPhoneLifecycle("scene")
        #if DEBUG
        lanProbeWaitTask?.cancel()
        lanProbeWaitTask = nil
        #endif
        saveTransfers()
        updateSourceIdleTimer()
        if continuedProcessing.canRunInBackground { return }
        guard isLANActive || !waitingLANIDs.isEmpty || !sendSubmissions.isEmpty else { return }
        guard continuedProcessing.isRequesting else {
            parkLANQueue(message: "等待恢复", resumeOnForeground: true)
            return
        }
        // The lease only bridges the asynchronous grant; continued processing
        // owns the runtime for the actual transfer.
        backgroundTransition = true
        #if DEBUG && targetEnvironment(simulator)
        if queueProbeRequest == nil {
            backgroundTransitionLease = UIApplication.shared.beginBackgroundTask(withName: "LAN transfer handoff") { [weak self] in
                Task { @MainActor in self?.parkLANQueue(message: "等待恢复", resumeOnForeground: true) }
            }
        }
        #else
        backgroundTransitionLease = UIApplication.shared.beginBackgroundTask(withName: "LAN transfer handoff") { [weak self] in
            Task { @MainActor in self?.parkLANQueue(message: "等待恢复", resumeOnForeground: true) }
        }
        #endif
        backgroundTransitionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, !self.isAppForeground, !self.continuedProcessing.canRunInBackground else { return }
            self.parkLANQueue(message: "等待恢复", resumeOnForeground: true)
        }
    }

    func stopLANTransfers() { queuePaused = false; cancelSendSubmissions(); stopLANTransfers(message: "已停止局域网传输", state: .cancelled, includeWaiting: true) }

    func sceneDidBecomeInactive() {
        #if DEBUG
        observedPhonePhase = "inactive"
        #endif
        recordPhoneLifecycle("scene")
    }

    private func recordPhoneLifecycle(_ kind: String, event: LANTransferEvent? = nil) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-lan-record-lifecycle") else { return }
        let url = transferIndex.deletingLastPathComponent().appendingPathComponent("lan-phone-lifecycle.json")
        var entries = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
        var entry: [String: Any] = ["time": Date().timeIntervalSince1970, "kind": kind,
            "scenePhase": observedPhonePhase, "runtimeGranted": continuedProcessing.canRunInBackground,
            "queuedFiles": transfers.filter { $0.method == .localNetwork && $0.state.isPending }.count]
        entry["runtimeRequestPending"] = continuedProcessing.isRequesting
        entry["runtimeFailure"] = continuedProcessing.lastFailure
        if WCSession.isSupported() {
            entry["paired"] = WCSession.default.isPaired
            entry["watchAppInstalled"] = WCSession.default.isWatchAppInstalled
            entry["reachable"] = WCSession.default.isReachable
        }
        if let event {
            entry["sessionID"] = event.sessionID; entry["fileID"] = event.fileID
            entry["completedBytes"] = event.completedBytes; entry["totalBytes"] = event.totalBytes
        }
        entries.append(entry)
        if entries.count > 2_000 { entries.removeFirst(entries.count - 2_000) }
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    func configureTransferQueueProbe(request: @escaping ([String: Any]) async throws -> [String: Any],
                                     persistenceDirectory: URL? = nil, automaticallyGrantBackground: Bool = true) {
        continuedProcessing.configureProbe(automaticallyGrant: automaticallyGrantBackground)
        configureContinuedProcessing()
        queueProbeRequest = request
        queueProbePersistenceDirectory = persistenceDirectory
        transfers = []
        waitingLANIDs = []; queuedLANSources = [:]
        currentLANOrder.removeAll(); backgroundTrackedIDs.removeAll()
        lanServer = LANHTTPServer(allowLoopbackForTesting: true)
    }

    func receiveTransferQueueProbeEvent(_ event: LANTransferEvent) { handleLANEvent(event) }

    func restoreTransferQueueForProbe() throws {
        transfers = try JSONDecoder().decode([TransferRecord].self, from: Data(contentsOf: persistedTransferIndex))
        restoreLANQueue()
    }
    #endif

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
            for _ in 0..<600 {
                guard !Task.isCancelled, let self, self.isAppForeground else { return }
                self.refreshConnection()
                if WCSession.isSupported(), WCSession.default.activationState == .activated,
                   WCSession.default.isPaired, WCSession.default.isWatchAppInstalled {
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

    private func startNextLANBatch() {
        guard queueMutationDepth == 0, !isLANActive, !isUpdatingTransferControls,
              canProcessLAN, watchIsReachable else { return }
        waitingLANIDs.removeAll { id in !transfers.contains(where: { $0.id == id && $0.state.isPending }) }
        var ids: [String] = []
        var manifestBytes = 6_000 // Credentials, endpoints and up to 100 paused IDs.
        for id in waitingLANIDs {
            guard let record = transfers.first(where: { $0.id == id }), record.state == .queued,
                  let hash = record.sourceSHA256 else { continue }
            let file = LANTransferFile(id: id, folder: record.folder, fileName: record.fileName,
                                       byteCount: record.totalBytes, sha256: hash)
            let bytes = ((try? JSONEncoder().encode(file).count) ?? 1_024) + 1
            if ids.count == 100 || manifestBytes + bytes > 50_000 { break }
            ids.append(id); manifestBytes += bytes
        }
        guard !ids.isEmpty else { return }
        let chosen = Set(ids)
        waitingLANIDs.removeAll { chosen.contains($0) }
        lanRecordIDs = chosen
        currentLANOrder = ids
        isPreparingLAN = true
        lanHandshakeAccepted = false
        lanStatus = "正在准备局域网传输…"
        let generation = UUID()
        lanGeneration = generation
        updateSourceIdleTimer()
        saveTransfers()
        lanPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.requestLANControl(LANTransferCommand(sessionID: UUID().uuidString, kind: .status, fileID: nil))
                guard !Task.isCancelled, self.lanGeneration == generation else { return }
                if let oldSession = snapshot.events.first?.sessionID {
                    _ = try await self.requestLANControl(LANTransferCommand(sessionID: oldSession, kind: .stop, fileID: nil, preservePartialFiles: true))
                }
                guard !Task.isCancelled, self.lanGeneration == generation else { return }
                var sources: [LANTransferSource] = []
                for id in ids {
                    guard let record = self.transfers.first(where: { $0.id == id }), record.state.isPending,
                          let track = self.queuedLANSources[id] else { continue }
                    guard (try? TransferSourceVersion.read(track.url)) == record.sourceVersion else {
                        self.updateTransfer(id: id, state: .outdated, message: "本地文件已更新，请重新发送")
                        continue
                    }
                    sources.append(LANTransferSource(id: id, folder: track.folder, fileName: track.fileName, url: track.url))
                }
                guard !sources.isEmpty else { self.finishLANIfComplete(); return }
                let prepared = try await self.lanServer.start(sources: sources)
                guard self.lanGeneration == generation, self.canProcessLAN, !Task.isCancelled else { return }
                var matched = Set<String>()
                for offset in stride(from: 0, to: prepared.files.count, by: LANInventoryWire.maximumFiles) {
                    let files = Array(prepared.files[offset..<min(prepared.files.count, offset + LANInventoryWire.maximumFiles)])
                    matched.formUnion(try await self.requestInventory(LANInventoryRequest(requestID: UUID().uuidString, files: files)).matchedFileIDs)
                }
                guard self.lanGeneration == generation, !Task.isCancelled else { return }
                for file in prepared.files {
                    guard let record = self.transfers.first(where: { $0.id == file.id }), record.state.isPending,
                          let track = self.queuedLANSources[file.id] else { continue }
                    if file.sha256 != record.sourceSHA256 || (try? TransferSourceVersion.read(track.url)) != record.sourceVersion {
                        self.updateTransfer(id: file.id, state: .outdated, message: "本地文件已更新，请重新发送")
                    } else if matched.contains(file.id) {
                        self.updateTransfer(id: file.id, state: .stored, message: "已在手表中")
                    }
                }
                let pendingIDs = Set(self.transfers.filter { self.lanRecordIDs.contains($0.id) && $0.state.isPending }.map(\.id))
                for file in prepared.files where !pendingIDs.contains(file.id) { self.lanServer.cancel(fileID: file.id) }
                guard !pendingIDs.isEmpty else { self.finishLANIfComplete(); return }
                let offer = LANTransferOffer(sessionID: prepared.sessionID, token: prepared.token,
                    baseURLs: prepared.baseURLs, expiresAt: prepared.expiresAt,
                    files: prepared.files.filter { pendingIDs.contains($0.id) },
                    pausedFileIDs: self.transfers.filter { self.lanRecordIDs.contains($0.id) && $0.state == .paused }.map(\.id))
                #if DEBUG && targetEnvironment(simulator)
                try LANTransferValidation.validate(offer, allowLoopback: self.queueProbeRequest != nil)
                #else
                try LANTransferValidation.validate(offer)
                #endif
                let message = try LANTransferWire.message(offer, type: LANTransferWire.offerType)
                guard let encoded = message["payload"] as? Data, encoded.count <= 55_000 else { throw self.lanError("传输清单过长，请减少单次发送的歌曲数量。") }
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
                let response = try await self.requestLiveMessage(message)
                guard self.lanGeneration == generation else { return }
                guard response["accepted"] as? Bool == true else { throw self.lanError(response["message"] as? String ?? "手表未能接收歌曲。") }
                self.confirmLANHandshake()
                self.lanStatus = "局域网传输中"
                self.refreshProgress()
            } catch {
                guard self.lanGeneration == generation, !self.lanHandshakeAccepted else { return }
                self.stopLANTransfers(message: error.localizedDescription, state: .failed)
            }
        }
    }

    private func stopLANTransfers(message: String, state: TransferRecord.State, notifyWatch: Bool = true, includeWaiting: Bool = false) {
        guard isLANActive || !lanRecordIDs.isEmpty || (includeWaiting && !waitingLANIDs.isEmpty) else { return }
        let sessionID = activeLANSessionID
        let ids = includeWaiting ? lanRecordIDs.union(waitingLANIDs) : lanRecordIDs
        closeLANSession()
        if includeWaiting {
            waitingLANIDs.removeAll()
            ids.forEach { queuedLANSources.removeValue(forKey: $0) }
        }
        if notifyWatch, let sessionID { sendLANCommand(LANTransferCommand(sessionID: sessionID, kind: .stop, fileID: nil)) }
        for id in ids { updateTransfer(id: id, state: state, message: message, onlyIfPending: true) }
        lanStatus = message
        refreshProgress()
        updateSourceIdleTimer()
        if !includeWaiting { startNextLANBatch() }
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
        for id in lanRecordIDs { queuedLANSources.removeValue(forKey: id) }
        lanRecordIDs.removeAll()
        currentLANOrder.removeAll()
        lanCompletedBytes.removeAll()
        updateSourceIdleTimer()
    }

    private func finishLANIfComplete() {
        guard !lanRecordIDs.isEmpty,
              !transfers.contains(where: { lanRecordIDs.contains($0.id) && $0.state.isPending }) else { return }
        let allStored = transfers.filter { lanRecordIDs.contains($0.id) }.allSatisfy { $0.state == .stored }
        closeLANSession()
        lanStatus = allStored ? "局域网传输完成" : "局域网传输已结束"
        startNextLANBatch()
    }

    private func sendLANCommand(_ command: LANTransferCommand) {
        #if DEBUG && targetEnvironment(simulator)
        if let queueProbeRequest, let message = try? LANTransferWire.message(command, type: LANTransferWire.commandType) {
            Task { _ = try? await queueProbeRequest(message) }
            return
        }
        #endif
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
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if event.kind != .progress || now - lastPhoneProgressLog >= 5 {
            lastPhoneProgressLog = now
            recordPhoneLifecycle("transfer-" + event.kind.rawValue, event: event)
        }
        #endif
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
        #if DEBUG
        let connectionLog = "connection-\(session.activationState.rawValue)-\(session.isPaired)-\(session.isWatchAppInstalled)-\(session.isReachable)"
        if lastPhoneConnectionLog != connectionLog {
            lastPhoneConnectionLog = connectionLog
            recordPhoneLifecycle(connectionLog)
        }
        #endif
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
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async { self.refreshConnection() }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.refreshConnection() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshConnection(); self.refreshTransferControlState()
            self.processSendSubmissions(); self.startNextLANBatch()
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
            guard let event = LANTransferWire.decode(LANTransferEvent.self, from: message, type: LANTransferWire.eventType) else { return }
            self?.handleLANEvent(event)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor [weak self] in
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
private final class LANMessageReplyGate {
    private var continuation: CheckedContinuation<[String: Any], Error>?
    var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<[String: Any], Error>) { self.continuation = continuation }

    func finish(_ result: Result<[String: Any], Error>) {
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

@MainActor
private struct LANSendSubmission {
    let id: UUID
    let tracks: [PhoneTrack]
    let completion: LANEnqueueCompletion
}
