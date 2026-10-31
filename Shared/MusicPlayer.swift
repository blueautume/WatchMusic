import AVFoundation
import Combine
import MediaPlayer
import UIKit
import OSLog

/// Local audio engine. File URLs stay on-device; playback never depends on the phone.
@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    typealias SessionActivation = (@escaping @MainActor (Bool, String?) -> Void) -> Void
    typealias SessionActivationWithError = (@escaping @MainActor (Bool, NSError?) -> Void) throws -> Void

    private enum ActivationResult: Sendable {
        case activated
        case cancelled
        case failed(String?)
    }

    @Published private(set) var currentURL: URL?
    @Published private(set) var queue: [URL] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    // AVAudioPlayer owns the running audio clock. Only discontinuous position
    // changes publish; views that display its clock redraw locally with TimelineView.
    @Published private var playbackPosition: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var title = L10n.text("未选择歌曲")
    @Published private(set) var artist = L10n.text("本地音乐")
    @Published private(set) var album = ""
    @Published private(set) var artworkData: Data?
    @Published private(set) var routeDescription = L10n.text("选择音频输出")
    @Published private(set) var audioOutput = AudioOutputPresentation.disconnected
    @Published private(set) var isSelectingAudioOutput = false
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var mode: PlaybackMode = .sequential
    @Published private(set) var sleepTimerDeadline: Date?
    @Published var errorMessage: String?

    var formatName: String {
        currentURL.flatMap { AudioFileFormat.format(for: $0) }?.displayName ?? L10n.text("音频")
    }

    var elapsed: TimeInterval {
        reachedEnd ? duration : (audioPlayer?.currentTime ?? playbackPosition)
    }

    var sleepRemaining: TimeInterval? {
        sleepTimerDeadline.map { max(0, $0.timeIntervalSinceNow) }
    }

    private var audioPlayer: AVAudioPlayer?
    private var activationID = UUID()
    private var observers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var resumeAfterInterruption = false
    private var sleepTimerTask: Task<Void, Never>?
    private var history: [URL] = []
    private var reachedEnd = false
    private var metadataTask: Task<Void, Never>?
    private var isApplicationInBackground = false
    private var releasesIdleAudioSession = false
    private var audioSessionNeedsDeactivation = false
    private var audioSessionGeneration: UInt64 = 0
    private var nativeActivationLease: UUID?
    private var nativeCleanupID: UUID?
    private var hasPreparedAudioResources = false
    private var pendingOutputActivations = Set<UUID>()
    private var nativeOutputObservations: [UUID: Bool] = [:]
    private struct PlaybackActivation {
        let id: UUID
        let url: URL
        let tracks: [URL]
        let beganWithoutOutput: Bool
        let waitsForForegroundReturn: Bool
        var hasObservedOutput: Bool
        var isAuthorized = false
        let start: @MainActor () -> Void
    }
    private var playbackActivation: PlaybackActivation?
    private var isApplicationActive = true
    private var cachedArtworkData: Data?
    private var cachedSystemArtwork: MPMediaItemArtwork?
    private let makeAudioPlayer: (URL) throws -> AVAudioPlayer
    private let activateAudioSession: SessionActivation?
    private let activateAudioSessionWithError: SessionActivationWithError?
    private let audioSessionExecutor: AudioSessionExecutor
    private let audioOutputPorts: (() -> [AudioOutputPort])?
    private let deactivateAudioSession: (() throws -> Void)?
    private let publishNowPlayingInfo: ([String: Any]?) -> Void
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let logger = Logger(subsystem: "WatchMusic", category: "AudioSession")
    private static let nativeAudioSessionExecutor = makeNativeAudioSessionExecutor()

    private var usesNativeAudioSession: Bool { activateAudioSession == nil && activateAudioSessionWithError == nil }

    override convenience init() {
        self.init(makeAudioPlayer: { try AVAudioPlayer(contentsOf: $0) })
    }

    /// Dependencies keep session activation and completion transitions testable
    /// without starting a simulator audio output or waiting for a physical route.
    init(makeAudioPlayer: @escaping (URL) throws -> AVAudioPlayer,
         activateAudioSession: SessionActivation? = nil,
         activateAudioSessionWithError: SessionActivationWithError? = nil,
         audioSessionExecutor: AudioSessionExecutor? = nil,
         audioOutputPorts: (() -> [AudioOutputPort])? = nil,
         deactivateAudioSession: (() throws -> Void)? = nil,
         publishNowPlayingInfo: @escaping ([String: Any]?) -> Void = { MPNowPlayingInfoCenter.default().nowPlayingInfo = $0 }) {
        self.makeAudioPlayer = makeAudioPlayer
        self.activateAudioSession = activateAudioSession
        self.activateAudioSessionWithError = activateAudioSessionWithError
        self.audioSessionExecutor = audioSessionExecutor ?? Self.nativeAudioSessionExecutor
        self.audioOutputPorts = audioOutputPorts
        self.deactivateAudioSession = deactivateAudioSession
        self.publishNowPlayingInfo = publishNowPlayingInfo
        super.init()
        let defaults = UserDefaults.standard
        mode = PlaybackMode(rawValue: defaults.string(forKey: "player.mode") ?? "") ?? .sequential
        playbackRate = defaults.double(forKey: "player.rate")
        if !(0.5...2).contains(playbackRate) { playbackRate = 1 }
        // Earlier builds persisted a separate app gain. Remove it so system
        // volume remains the only user-controlled level, including after upgrade.
        if defaults.object(forKey: "player.volume") != nil { defaults.removeObject(forKey: "player.volume") }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let previousPorts = Self.outputPorts(previous?.outputs ?? [])
            // NotificationCenter delivers this observer on .main. Handle the
            // captured event synchronously so it cannot later cancel or mark a
            // new playback/native request created after the notification.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioOutputRouteDidChange(reason: reason, previousPorts: previousPorts)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in self?.handleInterruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activationID = UUID()
                self.playbackActivation = nil
                self.pendingOutputActivations.removeAll()
                self.nativeOutputObservations.removeAll()
                self.isPreparing = false
                self.refreshOutputSelectionState()
                self.resumeAfterInterruption = false
                self.playbackPosition = self.elapsed
                self.audioPlayer = nil
                self.hasPreparedAudioResources = false
                self.audioSessionNeedsDeactivation = false
                self.audioSessionGeneration &+= 1
                self.nativeActivationLease = nil
                self.nativeCleanupID = nil
                if self.usesNativeAudioSession { self.audioSessionExecutor.invalidate() }
                self.releasesIdleAudioSession = true
                self.isPlaying = false
                self.updateRoute()
                self.savePlayback()
                self.updateNowPlaying()
                self.errorMessage = L10n.text("音频服务已重启，请重新选择歌曲播放。")
            }
        })
        configureRemoteCommands()
        restorePlayback()
        updateRoute()
    }

    deinit {
        metadataTask?.cancel()
        sleepTimerTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        commandTargets.forEach { $0.0.removeTarget($0.1) }
    }

    func play(_ url: URL, in tracks: [URL]) {
        startPlayback(url, in: tracks, recordHistory: true)
    }

    private func startPlayback(_ url: URL, in tracks: [URL], recordHistory: Bool) {
        cancelPlaybackActivation()
        let validTracks = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard validTracks.contains(url) else {
            errorMessage = L10n.text("歌曲文件已被移动或删除，请刷新音乐库。")
            releaseAudioResourcesIfIdle()
            return
        }
        activateForPlayback(url: url, tracks: validTracks, failureMessage: L10n.text("无法连接音频输出，请连接耳机后重试。")) { [weak self] in
            guard let self else { return }
            do {
                let nextPlayer = try self.makePlayer(url)
                guard nextPlayer.play() else { throw PlayerError.cannotPlay }
                self.audioPlayer?.stop()
                if self.queue != validTracks { self.history.removeAll() }
                if recordHistory, let current = self.currentURL, current != url, validTracks.contains(current) { self.history.append(current) }
                self.audioPlayer = nextPlayer
                self.queue = validTracks
                self.currentURL = url
                self.playbackPosition = 0
                self.reachedEnd = false
                self.duration = nextPlayer.duration
                self.isPlaying = true
                self.title = url.deletingPathExtension().lastPathComponent
                self.artist = L10n.text("本地音乐")
                self.album = url.deletingLastPathComponent().lastPathComponent
                self.artworkData = nil
                self.loadMetadata(url)
                self.updateRoute()
                self.updateNowPlaying()
                self.savePlayback()
            } catch {
                self.errorMessage = L10n.format("无法播放此文件：%@", error.localizedDescription)
                self.capturePlaybackState()
            }
        }
    }

    func togglePlayback() {
        guard !isPreparing else { return }
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        // Invalidate an outstanding route activation so a pause cannot start sound later.
        cancelPlaybackActivation()
        resumeAfterInterruption = false
        audioPlayer?.pause()
        isPlaying = false
        playbackPosition = elapsed
        savePlayback()
        updateNowPlaying()
        releaseAudioResourcesIfIdle()
    }

    func resume() {
        guard let url = currentURL else { return }
        guard let audioPlayer else {
            if loadPaused(url, in: queue, position: elapsed) { resume() }
            else { errorMessage = L10n.text("无法恢复此文件，请重新选择歌曲。") }
            return
        }
        activateForPlayback(url: url, tracks: queue, failureMessage: L10n.text("恢复播放失败，请检查耳机连接。")) { [weak self] in
            guard let self else { return }
            if self.reachedEnd || audioPlayer.currentTime >= audioPlayer.duration - 0.1 { audioPlayer.currentTime = 0 }
            self.reachedEnd = false
            audioPlayer.rate = Float(self.playbackRate)
            self.hasPreparedAudioResources = true
            self.isPlaying = audioPlayer.prepareToPlay() && audioPlayer.play()
            if !self.isPlaying { self.errorMessage = L10n.text("恢复播放失败，请重新选择歌曲。") }
            self.playbackPosition = audioPlayer.currentTime
            self.updateRoute()
            self.updateNowPlaying()
            self.savePlayback()
        }
    }

    func previous() {
        if elapsed > 3 {
            let replacesPendingTrack = playbackActivation.map { $0.url != currentURL } == true
            if replacesPendingTrack { pause() }
            seek(to: 0)
            if replacesPendingTrack { resume() }
            return
        }
        if isPreparing { pause() }
        guard let currentURL, let index = queue.firstIndex(of: currentURL) else { return }
        if mode == .shuffle, let previous = history.popLast(), queue.contains(previous) {
            startPlayback(previous, in: queue, recordHistory: false)
        } else if let index = PlaybackQueueLogic.previousIndex(current: index, count: queue.count) {
            play(queue[index], in: queue)
        }
    }

    func next() {
        if isPreparing { pause() }
        advance(completed: false)
    }

    private func advance(completed: Bool) {
        guard let currentURL, let index = queue.firstIndex(of: currentURL),
              let next = PlaybackQueueLogic.nextIndex(current: index, count: queue.count, mode: mode, completed: completed) else {
            isPlaying = false
            reachedEnd = true
            playbackPosition = duration
            updateNowPlaying()
            savePlayback()
            releaseAudioResourcesIfIdle()
            return
        }
        play(queue[next], in: queue)
    }

    func seek(to value: TimeInterval) {
        guard value.isFinite, let audioPlayer else { return }
        reachedEnd = false
        audioPlayer.currentTime = min(max(value, 0), duration)
        playbackPosition = audioPlayer.currentTime
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
        setSleepTimer(until: minutes.flatMap { $0 > 0 ? Date().addingTimeInterval(Double($0) * 60) : nil })
    }

    /// A single cancellable deadline drives the action; countdown text has its own local UI clock.
    func setSleepTimer(until deadline: Date?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerDeadline = deadline
        guard let deadline else { return }
        sleepTimerTask = Task { [weak self] in
            do {
                // Re-evaluate after waking so a wall-clock adjustment cannot fire early.
                while deadline > Date() {
                    try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
                }
                try Task.checkCancellation()
            } catch { return }
            guard let self, self.sleepTimerDeadline == deadline else { return }
            self.pause()
            self.setSleepTimer(until: nil)
        }
    }

    /// Call on a scene lifecycle transition; never pause local background audio here.
    func savePlaybackPosition() {
        savePlayback()
        updateNowPlaying()
    }

    /// Inactive also covers system route pickers. Only an actual background
    /// transition releases paused audio; real playback and pending user requests
    /// keep their route, queue and system controls.
    func setApplicationInBackground(_ value: Bool) {
        isApplicationInBackground = value
        releaseAudioResourcesIfIdle()
    }

    /// A system output picker makes the scene inactive without backgrounding it.
    /// Finish its original playback request only after the app is active again.
    func setApplicationActive(_ value: Bool) {
        isApplicationActive = value
        if value {
            updateRoute()
            completeAuthorizedPlaybackIfReady()
        }
    }

    private func releaseAudioResourcesIfIdle() {
        guard isApplicationInBackground || releasesIdleAudioSession,
              !isPlaying, !isPreparing, pendingOutputActivations.isEmpty else { return }
        if hasPreparedAudioResources {
            playbackPosition = elapsed
            // AVAudioPlayer.stop frees prepared hardware without resetting its
            // currentTime. Keep the instance for the existing resume path.
            audioPlayer?.stop()
            hasPreparedAudioResources = false
        }
        guard audioSessionNeedsDeactivation else { return }
        if let deactivateAudioSession {
            // Existing deterministic hooks keep their synchronous semantics.
            do {
                try deactivateAudioSession()
                audioSessionNeedsDeactivation = false
            } catch {
                // Retry only on another lifecycle/audio event.
            }
            return
        }
        guard nativeCleanupID == nil else { return }
        let cleanupID = UUID()
        let generation = audioSessionGeneration
        nativeCleanupID = cleanupID
        audioSessionExecutor.deactivate(expectedActivationID: nativeActivationLease) { [weak self] error in
            guard let self, self.nativeCleanupID == cleanupID else { return }
            self.nativeCleanupID = nil
            guard self.audioSessionGeneration == generation else {
                self.releaseAudioResourcesIfIdle()
                return
            }
            if error == nil { self.audioSessionNeedsDeactivation = false }
            // Failed cleanup remains pending for the next event, without a timer.
        }
    }

    func stop() {
        pause()
        audioPlayer?.stop()
        hasPreparedAudioResources = false
        audioPlayer = nil
        currentURL = nil
        queue = []
        history.removeAll()
        reachedEnd = false
        playbackPosition = 0
        duration = 0
        title = L10n.text("未选择歌曲")
        artist = L10n.text("本地音乐")
        album = ""
        artworkData = nil
        cachedArtworkData = nil
        cachedSystemArtwork = nil
        metadataTask?.cancel()
        setSleepTimer(minutes: nil)
        UserDefaults.standard.removeObject(forKey: "player.session")
        publishNowPlayingInfo(nil)
        pendingOutputActivations.removeAll()
        nativeOutputObservations.removeAll()
        refreshOutputSelectionState()
        releasesIdleAudioSession = true
        releaseAudioResourcesIfIdle()
    }

    func removeFromQueue(_ url: URL) {
        if isPreparing { cancelPlaybackActivation(); releaseAudioResourcesIfIdle() }
        if currentURL == url { stop() }
        else {
            queue.removeAll { $0 == url }
            history.removeAll { $0 == url }
            savePlayback()
            updateNowPlaying()
        }
    }

    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        play(queue[index], in: queue)
    }

    /// Removing an item from the queue does not delete its file.
    func removeQueueItem(at index: Int) {
        guard !isPreparing else { errorMessage = L10n.text("正在准备播放，请稍后编辑队列。"); return }
        guard queue.indices.contains(index) else { return }
        let removed = queue[index]
        var remaining = queue
        remaining.remove(at: index)
        history.removeAll { $0 == removed }
        guard currentURL == removed else {
            queue = remaining
            savePlayback()
            updateNowPlaying()
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
            errorMessage = L10n.text("后续歌曲无法播放，请在队列中选择其他歌曲。")
        }
    }

    func moveQueueItems(from indices: IndexSet, to destination: Int) {
        guard !isPreparing else { errorMessage = L10n.text("正在准备播放，请稍后编辑队列。"); return }
        let valid = indices.filter { queue.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { queue[$0] }
        for index in valid.reversed() { queue.remove(at: index) }
        let adjusted = max(0, min(queue.count, destination - valid.filter { $0 < destination }.count))
        queue.insert(contentsOf: moving, at: adjusted)
        savePlayback()
        updateNowPlaying()
    }

    func requestAudioOutput(onCompletion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !isPreparing else { onCompletion?(); return }
        let resetIdle = !isPlaying && currentOutputPorts().isEmpty
        Self.logger.info("manual output requested playing=\(self.isPlaying, privacy: .public) reset_idle=\(resetIdle, privacy: .public)")
        if resetIdle, usesNativeAudioSession, hasPreparedAudioResources {
            playbackPosition = elapsed
            audioPlayer?.stop()
            hasPreparedAudioResources = false
        }
        let requestID = UUID()
        pendingOutputActivations.insert(requestID)
        refreshOutputSelectionState()
        releasesIdleAudioSession = false
        activateSession(resetIdle: resetIdle) { [weak self] result in
            defer { onCompletion?() }
            guard let self else { return }
            guard self.pendingOutputActivations.remove(requestID) != nil else { return }
            self.refreshOutputSelectionState()
            self.updateRoute()
            switch result {
            case .activated: break
            case .cancelled:
                self.releasesIdleAudioSession = true
                self.capturePlaybackState()
            case .failed(let message):
                self.releasesIdleAudioSession = true
                self.errorMessage = message ?? L10n.text("请在手表控制中心连接 AirPods 或蓝牙耳机。")
                self.capturePlaybackState()
            }
        }
    }

    #if DEBUG
    /// Deterministic simulator layout inspection; omitted from Release builds.
    func prepareLayoutPreview(_ url: URL, position: Double = 5) {
        _ = loadPaused(url, in: [url], position: position)
    }
    #endif

    private func makePlayer(_ url: URL, prepare: Bool = true) throws -> AVAudioPlayer {
        let player = try makeAudioPlayer(url)
        guard player.duration.isFinite, player.duration > 0 else { throw PlayerError.invalidAudio }
        player.delegate = self
        player.enableRate = true
        player.rate = Float(playbackRate)
        player.volume = 1
        if prepare {
            hasPreparedAudioResources = true
            guard player.prepareToPlay() else { throw PlayerError.cannotPlay }
        }
        return player
    }

    private func cancelPlaybackActivation() {
        if isPreparing { releasesIdleAudioSession = true }
        activationID = UUID()
        playbackActivation = nil
        isPreparing = false
        refreshOutputSelectionState()
    }

    private func refreshOutputSelectionState() {
        let selecting = !pendingOutputActivations.isEmpty || playbackActivation?.beganWithoutOutput == true
        if isSelectingAudioOutput != selecting { isSelectingAudioOutput = selecting }
    }

    /// Keep one explicit play action through the native route picker. A false
    /// native completion is cancellation/failure, never permission to retry it
    /// later merely because headphones subsequently become available.
    private func activateForPlayback(url: URL, tracks: [URL], failureMessage: String, start: @escaping @MainActor () -> Void) {
        cancelPlaybackActivation()
        updateRoute()
        let requestID = UUID()
        activationID = requestID
        #if os(watchOS)
        let beganWithoutOutput = !audioOutput.isConnected
        #else
        let beganWithoutOutput = false
        #endif
        let needsForegroundPicker = beganWithoutOutput && currentOutputPorts().isEmpty && isApplicationActive
        playbackActivation = PlaybackActivation(id: requestID, url: url, tracks: tracks, beganWithoutOutput: beganWithoutOutput,
                                                waitsForForegroundReturn: needsForegroundPicker,
                                                hasObservedOutput: audioOutput.isConnected, start: start)
        isPreparing = true
        releasesIdleAudioSession = false
        resumeAfterInterruption = false
        refreshOutputSelectionState()
        activateSession { [weak self] result in
            guard let self, self.activationID == requestID, self.playbackActivation?.id == requestID else { return }
            switch result {
            case .cancelled:
                let requestedTracks = self.playbackActivation?.tracks ?? tracks
                self.updateRoute()
                self.cancelPlaybackActivation()
                self.errorMessage = nil
                // A first selection has no current song until playback starts.
                // Keep it silently selected so canceling the system picker
                // restores a usable Play button instead of an empty player.
                if self.currentURL == nil {
                    _ = self.loadPaused(url, in: requestedTracks, position: 0, onFailure: { error in
                        self.errorMessage = L10n.format("无法播放此文件：%@", error.localizedDescription)
                    })
                }
                self.capturePlaybackState()
                return
            case .failed(let message):
                self.updateRoute()
                self.cancelPlaybackActivation()
                self.errorMessage = message ?? failureMessage
                self.capturePlaybackState()
                return
            case .activated: break
            }
            self.playbackActivation?.isAuthorized = true
            self.updateRoute()
            self.completeAuthorizedPlaybackIfReady()
        }
    }

    private func completeAuthorizedPlaybackIfReady() {
        guard let request = playbackActivation, request.id == activationID, request.isAuthorized else { return }
        // Native activation success authorizes playback, including supported
        // built-in routes. The presentation snapshot can still be empty (for
        // example, after filtering a virtual route) and must never keep a
        // successful request preparing forever while both controls are locked.
        guard !request.waitsForForegroundReturn || isApplicationActive else { return }
        playbackActivation = nil
        isPreparing = false
        refreshOutputSelectionState()
        request.start()
    }

    /// The native adapter captures the previous route before its actor handoff.
    /// currentRoute may already have changed again when this event is handled.
    func audioOutputRouteDidChange(reason: AVAudioSession.RouteChangeReason?, previousPorts: [AudioOutputPort]) {
        if !previousPorts.isEmpty {
            for nativeID in Array(nativeOutputObservations.keys) { nativeOutputObservations[nativeID] = true }
        }
        let lostExternalOutput = AudioOutputPresentation(ports: previousPorts).isConnected
        let selectingInitialOutput = playbackActivation.map {
            $0.beganWithoutOutput && !$0.hasObservedOutput
        } == true && !isPlaying && !lostExternalOutput
        if reason == .oldDeviceUnavailable && !selectingInitialOutput {
            pause()
        }
        updateRoute()
        completeAuthorizedPlaybackIfReady()
    }

    private func activateSession(resetIdle: Bool = false, completion: @escaping @MainActor @Sendable (ActivationResult) -> Void) {
        audioSessionGeneration &+= 1
        let finish: @MainActor @Sendable (ActivationResult) -> Void = { [weak self] result in
            // A failed activation can still have touched the route. Releasing
            // an idle session is safe even when activation did not succeed.
            self?.audioSessionNeedsDeactivation = true
            completion(result)
            // Even an invalidated activation may have activated system audio.
            // Reconcile with the current intent so an old callback can never
            // deactivate a newer request that is preparing or playing.
            self?.releaseAudioResourcesIfIdle()
        }
        if let activateAudioSession {
            // The legacy test hook supplies already-rendered failure text. Do
            // not guess cancellation by parsing a localized description.
            activateAudioSession { success, message in finish(success ? .activated : .failed(message)) }
            return
        }
        let nativeID = UUID()
        let beganWithoutRoute = currentOutputPorts().isEmpty
        nativeOutputObservations[nativeID] = !beganWithoutRoute
        let nativeFinish: AudioSessionExecutor.ActivationCompletion = { [weak self] activated, error in
            var unselectedRoute = false
            var routeCount = 0
            if let self {
                let observedOutput = self.nativeOutputObservations.removeValue(forKey: nativeID) ?? true
                routeCount = self.currentOutputPorts().count
                unselectedRoute = beganWithoutRoute && !observedOutput && routeCount == 0
            }
            Self.logger.info("activation callback activated=\(activated, privacy: .public) error_domain=\(error?.domain ?? "", privacy: .public) error_code=\(error?.code ?? 0, privacy: .public) route_count=\(routeCount, privacy: .public)")
            finish(Self.nativeActivationResult(activated: activated, error: error, unselectedRoute: unselectedRoute))
        }
        if let activateAudioSessionWithError {
            do {
                try activateAudioSessionWithError(nativeFinish)
            } catch {
                nativeOutputObservations.removeValue(forKey: nativeID)
                finish(.failed(error.localizedDescription))
            }
            return
        }
        nativeActivationLease = nativeID
        #if os(watchOS)
        let policy = AVAudioSession.RouteSharingPolicy.longFormAudio
        #else
        let policy = AVAudioSession.RouteSharingPolicy.default
        #endif
        let configuration = AudioSessionExecutor.Configuration(category: AVAudioSession.Category.playback.rawValue,
                                                               mode: AVAudioSession.Mode.default.rawValue,
                                                               policy: policy.rawValue, options: 0)
        audioSessionExecutor.activate(id: nativeID, configuration: configuration, resetIdle: resetIdle,
                                                 onSetupFailure: { [weak self] error in
            self?.nativeOutputObservations.removeValue(forKey: nativeID)
            // Reset/configuration failures are not a native unselected result.
            finish(.failed(error.localizedDescription))
        }, completion: nativeFinish)
    }

    /// This factory is deliberately nonisolated: native dependency closures are
    /// Sendable worker code, never closures that inherit MusicPlayer's actor.
    nonisolated private static func makeNativeAudioSessionExecutor() -> AudioSessionExecutor {
        AudioSessionExecutor(configure: { configuration in
            guard let policy = AVAudioSession.RouteSharingPolicy(rawValue: configuration.policy) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(AVAudioSession.ErrorCode.badParam.rawValue))
            }
            try AVAudioSession.sharedInstance().setCategory(.init(rawValue: configuration.category),
                                                            mode: .init(rawValue: configuration.mode), policy: policy,
                                                            options: .init(rawValue: configuration.options))
        }, activate: { completion in
            let session = AVAudioSession.sharedInstance()
            #if os(watchOS)
            session.activate(options: []) { activated, error in completion(activated, error as NSError?) }
            #else
            do {
                try session.setActive(true)
                completion(true, nil)
            } catch { completion(false, error as NSError) }
            #endif
        }, deactivate: {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }, configurationMatches: { configuration in
            let session = AVAudioSession.sharedInstance()
            return session.category.rawValue == configuration.category && session.mode.rawValue == configuration.mode
                && session.routeSharingPolicy.rawValue == configuration.policy
                && session.categoryOptions.rawValue == configuration.options
        })
    }

    private static func nativeActivationResult(activated: Bool, error: NSError?, unselectedRoute: Bool) -> ActivationResult {
        #if os(watchOS)
        // Product policy: returning from an entirely unrouted native selection
        // without activation is an unselected result. Apple does not promise a
        // particular NSError for that return path. This policy applies only to
        // the native completion, never configuration throws or decoder errors.
        if !activated, unselectedRoute { return .cancelled }
        #endif
        if let error {
            if isExplicitUserCancellation(error) { return .cancelled }
            return .failed(error.localizedDescription)
        }
        if activated { return .activated }
        return .failed(nil)
    }

    private static func isExplicitUserCancellation(_ error: NSError, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return true }
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        // A concrete audio-session failure remains actionable even if one of
        // the service's internal operations happened to be canceled as well.
        if error.domain == NSOSStatusErrorDomain,
           let rawCode = AVAudioInteger(exactly: error.code),
           let code = AVAudioSession.ErrorCode(rawValue: rawCode), code != .none { return false }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isExplicitUserCancellation(underlying, depth: depth + 1)
    }

    private func currentOutputPorts() -> [AudioOutputPort] {
        if let audioOutputPorts { return audioOutputPorts() }
        return Self.outputPorts(AVAudioSession.sharedInstance().currentRoute.outputs)
    }

    nonisolated private static func outputPorts(_ outputs: [AVAudioSessionPortDescription]) -> [AudioOutputPort] {
        outputs.compactMap { output in
            // A virtual port is not audio hardware and must not appear as a
            // connected device or satisfy an initial playback's route gate.
            guard output.portType != .virtual else { return nil }
            let kind: AudioOutputPort.Kind
            switch output.portType {
            case .builtInSpeaker, .builtInReceiver: kind = .builtIn
            case .headphones: kind = .headphones
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: kind = .bluetooth
            case .airPlay: kind = .airPlay
            case .carAudio: kind = .carAudio
            default: kind = .other
            }
            return AudioOutputPort(kind: kind, name: output.portName)
        }
    }

    private func updateRoute() {
        let outputs = currentOutputPorts()
        if !outputs.isEmpty {
            for nativeID in Array(nativeOutputObservations.keys) { nativeOutputObservations[nativeID] = true }
        }
        let presentation = AudioOutputPresentation(ports: outputs)
        if audioOutput != presentation { audioOutput = presentation }
        if presentation.isConnected || (playbackActivation?.isAuthorized == true && !outputs.isEmpty) {
            playbackActivation?.hasObservedOutput = true
        }
        let description = outputs.isEmpty ? L10n.text("请连接 AirPods 或蓝牙耳机") : outputs.map(\.name).joined(separator: L10n.text("、"))
        if description != routeDescription { routeDescription = description }
    }

    /// Activation can stop an old output without a completion delegate event.
    /// Sample once at that event instead of relying on a recurring polling clock.
    private func capturePlaybackState() {
        isPlaying = audioPlayer?.isPlaying ?? false
        playbackPosition = elapsed
        savePlayback()
        updateNowPlaying()
        releaseAudioResourcesIfIdle()
    }

    private func handleInterruption(type rawType: UInt?, options rawOptions: UInt) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            // The system picker itself may interrupt an initially unrouted
            // session. Its still-pending native completion owns cancellation;
            // do not discard the user's play action just for this transition.
            if let request = playbackActivation, request.beganWithoutOutput,
               !request.isAuthorized, !isPlaying {
                return
            }
            let wasPlaying = isPlaying
            pause()
            resumeAfterInterruption = wasPlaying
        }
        else if type == .ended {
            let shouldResume = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            resumeAfterInterruption = false
            if shouldResume { resume() }
            else { completeAuthorizedPlaybackIfReady() }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === self.audioPlayer else { return }
            if flag {
                self.isPlaying = false
                self.reachedEnd = true
                self.playbackPosition = self.duration
                self.savePlayback()
                self.updateNowPlaying()
                // A user-initiated change may already be waiting for a route.
                if !self.isPreparing { self.advance(completed: true) }
            }
            else {
                self.isPlaying = false
                self.playbackPosition = player.currentTime
                self.savePlayback()
                self.updateNowPlaying()
                self.errorMessage = L10n.text("播放意外中断，请重新选择歌曲。")
            }
            self.releaseAudioResourcesIfIdle()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? L10n.text("文件可能已损坏")
        Task { @MainActor [weak self] in
            guard let self, player === self.audioPlayer else { return }
            self.isPlaying = false
            self.playbackPosition = player.currentTime
            self.errorMessage = L10n.format("音频解码失败：%@", message)
            self.updateNowPlaying()
            self.savePlayback()
            self.releaseAudioResourcesIfIdle()
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // A music queue uses track navigation in Control Center and on the
        // Lock Screen. Interval-skip commands otherwise take those positions.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        bind(center.playCommand) { $0.resume() }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.togglePlayback() }
        bind(center.nextTrackCommand) { $0.next() }
        bind(center.previousTrackCommand) { $0.previous() }
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
        guard let currentURL else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count]
        // The system owns the Now Playing card (including the Watch Smart Stack).
        // Keep its queue context current even when edits do not change the song.
        if let index = queue.firstIndex(of: currentURL) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
        }
        if let identifier = relativePath(currentURL) {
            info[MPNowPlayingInfoPropertyExternalContentIdentifier] = identifier
        }
        if cachedArtworkData != artworkData {
            cachedArtworkData = artworkData
            cachedSystemArtwork = artworkData.flatMap { data in
                guard let image = UIImage(data: data) else { return nil }
                return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
        if let cachedSystemArtwork { info[MPMediaItemPropertyArtwork] = cachedSystemArtwork }
        publishNowPlayingInfo(info)
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
    private func loadPaused(_ url: URL, in tracks: [URL], position: Double,
                            onFailure: ((Error) -> Void)? = nil) -> Bool {
        let player: AVAudioPlayer
        do { player = try makePlayer(url, prepare: false) }
        catch { onFailure?(error); return false }
        pause()
        audioPlayer?.stop()
        queue = tracks
        currentURL = url
        audioPlayer = player
        duration = player.duration
        player.currentTime = max(0, min(position.isFinite ? position : 0, duration))
        playbackPosition = player.currentTime
        reachedEnd = duration > 0 && player.currentTime >= duration - 0.1
        title = url.deletingPathExtension().lastPathComponent
        artist = L10n.text("本地音乐")
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
            case .invalidAudio: return L10n.text("音频无效或时长为零")
            case .cannotPlay: return L10n.text("无法开始播放，请检查音频文件和输出设备")
            }
        }
    }
}
