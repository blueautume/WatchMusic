import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Local audio engine. File URLs stay on-device; playback never depends on the phone.
@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var queue: [URL] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var title = "未选择歌曲"
    @Published private(set) var artist = "本地音乐"
    @Published private(set) var album = ""
    @Published private(set) var artworkData: Data?
    @Published private(set) var routeDescription = "选择音频输出"
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var mode: PlaybackMode = .sequential
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published var errorMessage: String?
    @Published var volume: Float = 1 {
        didSet {
            audioPlayer?.volume = min(1, max(0, volume))
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    var formatName: String {
        currentURL.flatMap { AudioFileFormat.format(for: $0) }?.displayName ?? "音频"
    }


    private var audioPlayer: AVAudioPlayer?
    private var timer: AnyCancellable?
    private var activationID = UUID()
    private var observers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var resumeAfterInterruption = false
    private var sleepDeadline: Date?
    private var history: [URL] = []
    private var reachedEnd = false
    private var lastSavedSecond = -1
    private var metadataTask: Task<Void, Never>?
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        mode = PlaybackMode(rawValue: defaults.string(forKey: "player.mode") ?? "") ?? .sequential
        playbackRate = defaults.double(forKey: "player.rate")
        if !(0.5...2).contains(playbackRate) { playbackRate = 1 }
        if defaults.object(forKey: "player.volume") != nil { volume = defaults.float(forKey: "player.volume") }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self.pause() }
                self.updateRoute()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in self?.handleInterruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioPlayer = nil
                self?.isPlaying = false
                self?.errorMessage = "音频服务已重启，请重新选择歌曲播放。"
            }
        })
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.tick()
        }
        configureRemoteCommands()
        restorePlayback()
        updateRoute()
    }

    deinit {
        metadataTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        commandTargets.forEach { $0.0.removeTarget($0.1) }
    }

    func play(_ url: URL, in tracks: [URL]) {
        startPlayback(url, in: tracks, recordHistory: true)
    }

    private func startPlayback(_ url: URL, in tracks: [URL], recordHistory: Bool) {
        let validTracks = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard validTracks.contains(url) else {
            errorMessage = "歌曲文件已被移动或删除，请刷新音乐库。"
            return
        }
        let requestID = UUID()
        activationID = requestID
        isPreparing = true
        activateSession { [weak self] success, message in
            guard let self, self.activationID == requestID else { return }
            self.isPreparing = false
            guard success else {
                self.errorMessage = message ?? "无法连接音频输出，请连接耳机后重试。"
                self.updateRoute()
                return
            }
            do {
                let nextPlayer = try self.makePlayer(url)
                guard nextPlayer.play() else { throw PlayerError.cannotPlay }
                self.audioPlayer?.stop()
                if self.queue != validTracks { self.history.removeAll() }
                if recordHistory, let current = self.currentURL, current != url, validTracks.contains(current) { self.history.append(current) }
                self.audioPlayer = nextPlayer
                self.queue = validTracks
                self.currentURL = url
                self.elapsed = 0
                self.reachedEnd = false
                self.duration = nextPlayer.duration
                self.isPlaying = true
                self.title = url.deletingPathExtension().lastPathComponent
                self.artist = "本地音乐"
                self.album = url.deletingLastPathComponent().lastPathComponent
                self.artworkData = nil
                self.loadMetadata(url)
                self.updateRoute()
                self.updateNowPlaying()
                self.savePlayback()
            } catch {
                self.errorMessage = "无法播放此文件：\(error.localizedDescription)"
                self.isPlaying = self.audioPlayer?.isPlaying ?? false
            }
        }
    }

    func togglePlayback() {
        guard !isPreparing else { return }
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        // Invalidate an outstanding route activation so a pause cannot start sound later.
        activationID = UUID()
        resumeAfterInterruption = false
        isPreparing = false
        audioPlayer?.pause()
        isPlaying = false
        savePlayback()
        updateNowPlaying()
    }

    func resume() {
        guard let url = currentURL else { return }
        guard let audioPlayer else { play(url, in: queue); return }
        let requestID = UUID()
        activationID = requestID
        isPreparing = true
        activateSession { [weak self] success, message in
            guard let self, self.activationID == requestID else { return }
            self.isPreparing = false
            guard success else { self.errorMessage = message ?? "恢复播放失败，请检查耳机连接。"; return }
            if self.reachedEnd || audioPlayer.currentTime >= audioPlayer.duration - 0.1 { audioPlayer.currentTime = 0 }
            self.reachedEnd = false
            audioPlayer.rate = Float(self.playbackRate)
            self.isPlaying = audioPlayer.prepareToPlay() && audioPlayer.play()
            if !self.isPlaying { self.errorMessage = "恢复播放失败，请重新选择歌曲。" }
            self.updateRoute()
            self.updateNowPlaying()
        }
    }

    func previous() {
        if elapsed > 3 { seek(to: 0); return }
        guard let currentURL, let index = queue.firstIndex(of: currentURL) else { return }
        if mode == .shuffle, let previous = history.popLast(), queue.contains(previous) {
            startPlayback(previous, in: queue, recordHistory: false)
        } else if let index = PlaybackQueueLogic.previousIndex(current: index, count: queue.count) {
            play(queue[index], in: queue)
        }
    }

    func next() { advance(completed: false) }

    private func advance(completed: Bool) {
        guard let currentURL, let index = queue.firstIndex(of: currentURL),
              let next = PlaybackQueueLogic.nextIndex(current: index, count: queue.count, mode: mode, completed: completed) else {
            isPlaying = false
            reachedEnd = true
            elapsed = duration
            updateNowPlaying()
            savePlayback()
            return
        }
        play(queue[next], in: queue)
    }

    func seek(to value: TimeInterval) {
        guard value.isFinite, let audioPlayer else { return }
        reachedEnd = false
        audioPlayer.currentTime = min(max(value, 0), duration)
        elapsed = audioPlayer.currentTime
        updateNowPlaying()
        savePlayback()
    }

    func skip(seconds: Double) { seek(to: elapsed + seconds) }

    func cycleMode() {
        let all = PlaybackMode.allCases
        let index = all.firstIndex(of: mode) ?? 0
        mode = all[(index + 1) % all.count]
        UserDefaults.standard.set(mode.rawValue, forKey: "player.mode")
    }

    func setRate(_ value: Double) {
        guard value.isFinite else { return }
        playbackRate = min(2, max(0.5, value))
        audioPlayer?.rate = Float(playbackRate)
        UserDefaults.standard.set(playbackRate, forKey: "player.rate")
        updateNowPlaying()
    }

    func setSleepTimer(minutes: Int?) {
        if let minutes, minutes > 0 {
            sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
            sleepRemaining = Double(minutes) * 60
        } else {
            sleepDeadline = nil
            sleepRemaining = nil
        }
    }

    func stop() {
        pause()
        audioPlayer?.stop()
        audioPlayer = nil
        currentURL = nil
        queue = []
        history.removeAll()
        reachedEnd = false
        elapsed = 0
        duration = 0
        title = "未选择歌曲"
        artist = "本地音乐"
        album = ""
        artworkData = nil
        metadataTask?.cancel()
        sleepDeadline = nil
        sleepRemaining = nil
        UserDefaults.standard.removeObject(forKey: "player.session")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func removeFromQueue(_ url: URL) {
        if isPreparing { activationID = UUID(); isPreparing = false }
        if currentURL == url { stop() } else { queue.removeAll { $0 == url }; history.removeAll { $0 == url }; savePlayback() }
    }

    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        play(queue[index], in: queue)
    }

    /// Removing an item from the queue does not delete its file.
    func removeQueueItem(at index: Int) {
        guard !isPreparing else { errorMessage = "正在准备播放，请稍后编辑队列。"; return }
        guard queue.indices.contains(index) else { return }
        let removed = queue[index]
        var remaining = queue
        remaining.remove(at: index)
        history.removeAll { $0 == removed }
        guard currentURL == removed else {
            queue = remaining
            savePlayback()
            return
        }
        guard !remaining.isEmpty else { stop(); return }
        let next = remaining[min(index, remaining.count - 1)]
        let shouldPlay = isPlaying
        if loadPaused(next, in: remaining, position: 0) {
            if shouldPlay { resume() }
        } else {
            stop()
            queue = remaining
            errorMessage = "后续歌曲无法播放，请在队列中选择其他歌曲。"
        }
    }

    func moveQueueItems(from indices: IndexSet, to destination: Int) {
        guard !isPreparing else { errorMessage = "正在准备播放，请稍后编辑队列。"; return }
        let valid = indices.filter { queue.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { queue[$0] }
        for index in valid.reversed() { queue.remove(at: index) }
        let adjusted = max(0, min(queue.count, destination - valid.filter { $0 < destination }.count))
        queue.insert(contentsOf: moving, at: adjusted)
        savePlayback()
    }

    func requestAudioOutput() {
        guard !isPreparing else { return }
        activateSession { [weak self] success, message in
            guard let self else { return }
            self.updateRoute()
            if !success { self.errorMessage = message ?? "请在手表控制中心连接 AirPods 或蓝牙耳机。" }
        }
    }

    #if DEBUG
    /// Deterministic simulator layout inspection; omitted from Release builds.
    func prepareLayoutPreview(_ url: URL, position: Double = 5) {
        _ = loadPaused(url, in: [url], position: position)
    }
    #endif

    private func makePlayer(_ url: URL, prepare: Bool = true) throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.duration.isFinite, player.duration > 0 else { throw PlayerError.invalidAudio }
        player.delegate = self
        player.enableRate = true
        player.rate = Float(playbackRate)
        player.volume = volume
        if prepare, !player.prepareToPlay() { throw PlayerError.cannotPlay }
        return player
    }

    private func activateSession(completion: @escaping @MainActor (Bool, String?) -> Void) {
        do {
            let session = AVAudioSession.sharedInstance()
            #if os(watchOS)
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            session.activate(options: []) { activated, error in
                let message = error?.localizedDescription
                Task { @MainActor in completion(activated && message == nil, message) }
            }
            #else
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            completion(true, nil)
            #endif
        } catch { completion(false, error.localizedDescription) }
    }

    private func tick() {
        if let player = audioPlayer {
            elapsed = reachedEnd ? duration : player.currentTime
            isPlaying = player.isPlaying
            let second = Int(elapsed)
            if isPlaying, second % 5 == 0, second != lastSavedSecond { lastSavedSecond = second; savePlayback() }
        }
        if let deadline = sleepDeadline {
            sleepRemaining = max(0, deadline.timeIntervalSinceNow)
            if deadline <= Date() { pause(); setSleepTimer(minutes: nil) }
        }
    }

    private func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        routeDescription = outputs.isEmpty ? "请连接 AirPods 或蓝牙耳机" : outputs.map(\.portName).joined(separator: "、")
    }

    private func handleInterruption(type rawType: UInt?, options rawOptions: UInt) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            let wasPlaying = isPlaying
            pause()
            resumeAfterInterruption = wasPlaying
        }
        else if type == .ended {
            let shouldResume = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            resumeAfterInterruption = false
            if shouldResume { resume() }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === self.audioPlayer else { return }
            if flag {
                // A user-initiated change may already be waiting for a route.
                if !self.isPreparing { self.advance(completed: true) }
            }
            else { self.isPlaying = false; self.errorMessage = "播放意外中断，请重新选择歌曲。" }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "文件可能已损坏"
        Task { @MainActor [weak self] in
            guard let self, player === self.audioPlayer else { return }
            self.isPlaying = false
            self.errorMessage = "音频解码失败：\(message)"
            self.updateNowPlaying()
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand) { $0.resume() }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.togglePlayback() }
        bind(center.nextTrackCommand) { $0.next() }
        bind(center.previousTrackCommand) { $0.previous() }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        bind(center.skipForwardCommand) { $0.skip(seconds: 15) }
        bind(center.skipBackwardCommand) { $0.skip(seconds: -15) }
        let seek = center.changePlaybackPositionCommand
        seek.isEnabled = true
        let target = seek.addTarget { [weak self] event in
            guard let value = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: value.positionTime) }
            return .success
        }
        commandTargets.append((seek, target))
    }

    private func bind(_ command: MPRemoteCommand, action: @escaping @MainActor (MusicPlayer) -> Void) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in if let self { action(self) } }
            return .success
        }
        commandTargets.append((command, token))
    }

    private func updateNowPlaying() {
        guard currentURL != nil else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artworkData, let image = UIImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadMetadata(_ url: URL) {
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            // Read bounded local tags first; malformed optional tags never block playback.
            let local = await Task.detached(priority: .utility) {
                let metadata = AudioMetadataReader.read(from: url)
                return (metadata, metadata.artworkData.flatMap { ArtworkDecoder.thumbnailData(from: $0) })
            }.value
            guard !Task.isCancelled, let self, self.currentURL == url else { return }
            if let title = local.0.title, !title.isEmpty { self.title = title }
            if let artist = local.0.artist, !artist.isEmpty { self.artist = artist }
            if let album = local.0.album, !album.isEmpty { self.album = album }
            self.artworkData = local.1
            self.updateNowPlaying()

            let asset = AVURLAsset(url: url)
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            var foundTitle: String?, foundArtist: String?, foundAlbum: String?, foundArtwork: Data?
            for item in metadata {
                guard !Task.isCancelled else { return }
                switch item.commonKey {
                case .commonKeyTitle: foundTitle = try? await item.load(.stringValue)
                case .commonKeyArtist: foundArtist = try? await item.load(.stringValue)
                case .commonKeyAlbumName: foundAlbum = try? await item.load(.stringValue)
                case .commonKeyArtwork: foundArtwork = try? await item.load(.dataValue)
                default: break
                }
            }
            let rawArtwork = foundArtwork
            let thumbnail = await Task.detached(priority: .utility) {
                rawArtwork.flatMap { ArtworkDecoder.thumbnailData(from: $0) }
            }.value
            guard !Task.isCancelled, self.currentURL == url else { return }
            if let foundTitle, !foundTitle.isEmpty { self.title = foundTitle }
            if let foundArtist, !foundArtist.isEmpty { self.artist = foundArtist }
            if let foundAlbum, !foundAlbum.isEmpty { self.album = foundAlbum }
            self.artworkData = thumbnail ?? local.1
            self.updateNowPlaying()
        }
    }

    private struct SavedPlayback: Codable { var paths: [String]; var current: String; var elapsed: Double }
    private func relativePath(_ url: URL) -> String? {
        let prefix = documents.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }
    private func savePlayback() {
        guard let currentURL, let current = relativePath(currentURL) else { return }
        let snapshot = SavedPlayback(paths: queue.compactMap(relativePath), current: current, elapsed: elapsed)
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: "player.session") }
    }
    private func restorePlayback() {
        guard let data = UserDefaults.standard.data(forKey: "player.session"),
              let saved = try? JSONDecoder().decode(SavedPlayback.self, from: data) else { return }
        func file(_ path: String) -> URL? {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            let url = documents.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let tracks = saved.paths.compactMap(file)
        guard let url = file(saved.current), tracks.contains(url) else { return }
        loadPaused(url, in: tracks, position: saved.elapsed)
    }

    @discardableResult
    private func loadPaused(_ url: URL, in tracks: [URL], position: Double) -> Bool {
        guard let player = try? makePlayer(url, prepare: false) else { return false }
        pause()
        audioPlayer?.stop()
        queue = tracks
        currentURL = url
        audioPlayer = player
        duration = player.duration
        player.currentTime = max(0, min(position.isFinite ? position : 0, duration))
        elapsed = player.currentTime
        reachedEnd = duration > 0 && elapsed >= duration - 0.1
        title = url.deletingPathExtension().lastPathComponent
        artist = "本地音乐"
        album = url.deletingLastPathComponent().lastPathComponent
        artworkData = nil
        loadMetadata(url)
        updateNowPlaying()
        savePlayback()
        return true
    }

    private enum PlayerError: LocalizedError {
        case invalidAudio, cannotPlay
        var errorDescription: String? {
            switch self {
            case .invalidAudio: return "音频无效或时长为零"
            case .cannotPlay: return "无法开始播放，请检查音频文件和输出设备"
            }
        }
    }
}
