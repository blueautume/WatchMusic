import Combine
import Foundation
import WatchConnectivity

/// Uses the libraries' existing WCSession delegate. Commands are live messages
/// only: reconnect refreshes state, never replays a queued play/pause/skip.
@MainActor
final class PlaybackControlCenter: ObservableObject {
    static let shared = PlaybackControlCenter()
    @Published private(set) var peerState: PlaybackControlState?
    @Published private(set) var isReachable = false
    @Published private(set) var isPeerConfirmed = false
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?

    #if os(watchOS)
    private let device = PlaybackControlDevice.watch
    private let counterpart = PlaybackControlDevice.phone
    #else
    private let device = PlaybackControlDevice.phone
    private let counterpart = PlaybackControlDevice.watch
    #endif
    private let processID = UUID().uuidString
    private var localSessionID: String?
    private var revision: Int64 = 0
    private var localState: PlaybackControlState?
    private weak var player: MusicPlayer?
    private var observation: AnyCancellable?
    private var heartbeat: AnyCancellable?
    private var publicationScheduled = false
    private var store = PlaybackPeerStateStore()
    private var commandGate = PlaybackCommandGate()
    private var queryID: String?
    private var commandID: String?
    #if DEBUG && targetEnvironment(simulator)
    private let isLayoutPreview = ProcessInfo.processInfo.arguments.contains("-preview-remote-playback") ||
        ProcessInfo.processInfo.arguments.contains("-preview-remote-paused")
    private var didPrepareLayoutPreview = false
    #endif

    var hasRemoteItem: Bool { peerState?.hasItem == true }
    var canControl: Bool { isReachable && isPeerConfirmed && hasRemoteItem && !isSending }

    func configure(player: MusicPlayer) {
        #if DEBUG && targetEnvironment(simulator)
        if isLayoutPreview { self.player = player; prepareLayoutPreview(); return }
        #endif
        guard self.player !== player else { connectionDidChange(); return }
        self.player = player
        observation = player.objectWillChange.sink { [weak self] _ in
            // @Published fires before mutation. Coalesce the engine's multiple
            // property changes into one snapshot after its main-actor turn.
            DispatchQueue.main.async { self?.schedulePublication() }
        }
        heartbeat = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.connectionDidChange()
        }
        captureLocalState()
        connectionDidChange()
    }

    func connectionDidChange() {
        #if DEBUG && targetEnvironment(simulator)
        if isLayoutPreview { prepareLayoutPreview(); return }
        #endif
        let ready = WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
        let changed = ready != isReachable
        isReachable = ready
        if !ready {
            queryID = nil; commandID = nil; isSending = false
            store.disconnect(); publishPeer()
            return
        }
        if changed { sendCurrentState() }
        refreshPeerState()
    }

    func send(_ action: PlaybackControlAction) {
        #if DEBUG && targetEnvironment(simulator)
        if isLayoutPreview {
            prepareLayoutPreview()
            guard let current = store.state, action == .play || action == .pause else { return }
            _ = store.confirm(PlaybackControlState(processID: current.processID, sessionID: current.sessionID,
                                                   revision: current.revision + 1, hasItem: true,
                                                   isPlaying: action == .play, isPreparing: false))
            publishPeer()
            return
        }
        #endif
        guard canControl, let target = peerState, let sessionID = target.sessionID else { return }
        lastError = nil
        let id = UUID().uuidString
        commandID = id; isSending = true
        let command = PlaybackControlCommand(targetProcessID: target.processID, targetSessionID: sessionID,
                                             action: action, issuedAt: Date())
        let request = envelope(.command, id: id, command: command)
        sendLive(request) { [weak self] result in
            guard let self, self.commandID == id else { return }
            self.commandID = nil; self.isSending = false
            switch result {
            case .success(let reply):
                if let state = reply.state { _ = self.store.confirm(state); self.publishPeer() }
                if reply.accepted != true { self.lastError = "播放状态已变化，请重试。"; self.refreshPeerState() }
            case .failure:
                self.lastError = "暂时无法控制，请连接后重试。"
                self.store.disconnect(); self.publishPeer()
                self.refreshPeerState()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.commandID == id else { return }
            self.commandID = nil; self.isSending = false
            self.lastError = "控制未确认，请重试。"
            self.store.disconnect(); self.publishPeer(); self.refreshPeerState()
        }
    }

    /// Return true whenever this namespace is present, even for invalid data,
    /// so it cannot fall through into file-transfer command handling.
    @discardableResult func handle(_ message: [String: Any], reply: (([String: Any]) -> Void)? = nil) -> Bool {
        guard message[PlaybackControlWire.key] != nil else { return false }
        #if DEBUG && targetEnvironment(simulator)
        if isLayoutPreview { reply?(["playbackAccepted": false]); return true }
        #endif
        guard let incoming = PlaybackControlWire.decode(message, from: counterpart) else {
            reply?(["playbackAccepted": false]); return true
        }
        captureLocalState()
        switch incoming.kind {
        case .query:
            reply?(response(to: incoming, accepted: true))
        case .state:
            if let state = incoming.state, store.update(state) { publishPeer() }
            else { refreshPeerState() }
            reply?(response(to: incoming, accepted: true))
        case .command:
            var accepted = false
            if let command = incoming.command, let localState, let player {
                switch commandGate.evaluate(requestID: incoming.requestID, command: command, current: localState) {
                case .duplicate: accepted = true
                case .reject: break
                case .execute:
                    if !player.isPreparing || command.action == .pause {
                        switch command.action {
                        case .play: if !player.isPlaying { player.resume() }
                        case .pause: player.pause()
                        case .previous: player.previousTrack()
                        case .next: player.next()
                        }
                        accepted = true
                    }
                }
            }
            captureLocalState()
            reply?(response(to: incoming, accepted: accepted))
        case .result:
            // Responses are accepted only inside their matching request closure.
            reply?(response(to: incoming, accepted: false))
        }
        return true
    }

    private func schedulePublication() {
        guard !publicationScheduled else { return }
        publicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publicationScheduled = false
            self.captureLocalState()
        }
    }

    private func captureLocalState() {
        let url = player?.currentURL
        // Track changes are part of one playback session. A queued pause must
        // still target the same owner after a successful next/previous command.
        if url == nil { localSessionID = nil }
        else if localSessionID == nil { localSessionID = UUID().uuidString }
        let hasItem = url != nil
        let playing = hasItem && player?.isPlaying == true
        let preparing = hasItem && player?.isPreparing == true
        if let old = localState, old.sessionID == localSessionID, old.hasItem == hasItem,
           old.isPlaying == playing, old.isPreparing == preparing { return }
        revision += 1
        localState = PlaybackControlState(processID: processID, sessionID: localSessionID, revision: revision,
                                          hasItem: hasItem, isPlaying: playing, isPreparing: preparing)
        sendCurrentState()
    }

    private func sendCurrentState() {
        #if DEBUG && targetEnvironment(simulator)
        if isLayoutPreview { return }
        #endif
        guard let localState, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable,
              let message = PlaybackControlWire.message(envelope(.state, state: localState)) else { return }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    private func refreshPeerState() {
        guard isReachable, queryID == nil else { return }
        let id = UUID().uuidString
        queryID = id
        sendLive(envelope(.query, id: id)) { [weak self] result in
            guard let self, self.queryID == id else { return }
            self.queryID = nil
            if case .success(let reply) = result, reply.accepted == true, let state = reply.state {
                _ = self.store.confirm(state)
            } else { self.store.disconnect() }
            self.publishPeer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.queryID == id else { return }
            self.queryID = nil; self.store.disconnect(); self.publishPeer()
        }
    }

    private enum LiveError: Error { case unavailable, invalidReply }

    private func sendLive(_ request: PlaybackControlEnvelope,
                          completion: @escaping (Result<PlaybackControlEnvelope, Error>) -> Void) {
        #if DEBUG && targetEnvironment(simulator)
        if isLayoutPreview { completion(.failure(LiveError.unavailable)); return }
        #endif
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable,
              let message = PlaybackControlWire.message(request) else { completion(.failure(LiveError.unavailable)); return }
        WCSession.default.sendMessage(message) { response in
            Task { @MainActor in
                guard let value = PlaybackControlWire.decode(response, from: self.counterpart), value.kind == .result,
                      value.requestID == request.requestID else { completion(.failure(LiveError.invalidReply)); return }
                completion(.success(value))
            }
        } errorHandler: { error in
            Task { @MainActor in completion(.failure(error)) }
        }
    }

    private func publishPeer() {
        if peerState != store.state { peerState = store.state }
        isPeerConfirmed = store.isConfirmed
    }

    private func envelope(_ kind: PlaybackControlEnvelope.Kind, id: String = UUID().uuidString,
                          state: PlaybackControlState? = nil, command: PlaybackControlCommand? = nil,
                          accepted: Bool? = nil) -> PlaybackControlEnvelope {
        PlaybackControlEnvelope(version: 1, kind: kind, sender: device, requestID: id,
                                state: state, command: command, accepted: accepted)
    }

    private func response(to request: PlaybackControlEnvelope, accepted: Bool) -> [String: Any] {
        PlaybackControlWire.message(envelope(.result, id: request.requestID, state: localState, accepted: accepted)) ?? [:]
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Isolated layout fixture. It never activates WC, sends any state/command,
    /// starts a heartbeat, or invokes a MusicPlayer operation.
    private func prepareLayoutPreview() {
        guard !didPrepareLayoutPreview else { return }
        didPrepareLayoutPreview = true
        _ = store.confirm(PlaybackControlState(processID: UUID().uuidString, sessionID: UUID().uuidString,
                                               revision: 1, hasItem: true,
                                               isPlaying: !ProcessInfo.processInfo.arguments.contains("-preview-remote-paused"),
                                               isPreparing: false))
        isReachable = true
        publishPeer()
    }
    #endif
}
