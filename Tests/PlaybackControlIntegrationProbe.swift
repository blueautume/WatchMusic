import Foundation

/// Exercises routing against the real, paused AVAudioPlayer engine. No command
/// that could start audio is accepted, and no audio route is activated.
@main struct PlaybackControlIntegrationProbe {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
        checks += 1
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass one valid audio fixture") }
        let fm = FileManager.default
        let defaults = UserDefaults.standard
        let keys = ["player.session", "player.mode", "player.rate", "player.volume"]
        var backup: [String: Any] = [:]
        for key in keys { if let value = defaults.object(forKey: key) { backup[key] = value }; defaults.removeObject(forKey: key) }
        let folder = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackControlProbe-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let a = folder.appendingPathComponent("A." + source.pathExtension)
        let b = folder.appendingPathComponent("B." + source.pathExtension)
        try fm.copyItem(at: source, to: a); try fm.copyItem(at: source, to: b)
        let player = MusicPlayer()
        defer {
            player.stop()
            for key in keys {
                if let value = backup[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.synchronize()
            try? fm.removeItem(at: folder)
        }
        player.prepareLayoutPreview(a)
        let center = PlaybackControlCenter.shared
        center.configure(player: player)
        #if os(watchOS)
        let owner = PlaybackControlDevice.watch, sender = PlaybackControlDevice.phone
        #else
        let owner = PlaybackControlDevice.phone, sender = PlaybackControlDevice.watch
        #endif
        func deliver(_ request: PlaybackControlEnvelope) -> PlaybackControlEnvelope {
            var response: [String: Any] = [:]
            expect(center.handle(PlaybackControlWire.message(request)!, reply: { response = $0 }), "playback namespace routed")
            return PlaybackControlWire.decode(response, from: owner)!
        }
        func query() -> PlaybackControlState {
            let response = deliver(PlaybackControlEnvelope(version: 1, kind: .query, sender: sender, requestID: UUID().uuidString))
            expect(response.accepted == true, "live state query response")
            return response.state!
        }
        func request(_ action: PlaybackControlAction, id: String = UUID().uuidString,
                     target: PlaybackControlState, session: String? = nil, age: Double = 0) -> PlaybackControlEnvelope {
            PlaybackControlEnvelope(version: 1, kind: .command, sender: sender, requestID: id,
                                    command: PlaybackControlCommand(targetProcessID: target.processID,
                                                                    targetSessionID: session ?? target.sessionID!, action: action,
                                                                    issuedAt: Date().addingTimeInterval(-age)))
        }
        let first = query()
        expect(first.hasItem && !first.isPlaying && !first.isPreparing, "paused engine state exposed without playing")
        let pause = request(.pause, target: first)
        expect(deliver(pause).accepted == true && !player.isPlaying, "real pause handler acknowledged without audio")
        expect(deliver(pause).accepted == true && !player.isPlaying, "duplicate pause acknowledged safely")
        expect(deliver(request(.play, id: pause.requestID, target: first)).accepted == false, "ID reuse cannot turn pause into play")
        expect(!player.isPlaying && !player.isPreparing, "reused command did not activate audio")
        expect(deliver(request(.play, target: first, session: UUID().uuidString)).accepted == false, "stale target play rejected")
        expect(deliver(request(.play, target: first, age: 60)).accepted == false, "delayed play rejected")
        expect(!player.isPlaying && !player.isPreparing, "rejected plays never activate audio")

        let peerState = PlaybackControlState(processID: UUID().uuidString, sessionID: UUID().uuidString,
                                             revision: 1, hasItem: true, isPlaying: true, isPreparing: false)
        let stateMessage = PlaybackControlEnvelope(version: 1, kind: .state, sender: sender,
                                                  requestID: UUID().uuidString, state: peerState)
        expect(center.handle(PlaybackControlWire.message(stateMessage)!), "peer state accepted by namespace")
        expect(!player.isPlaying && player.currentURL == a, "peer playing state never starts or switches local media")
        player.prepareLayoutPreview(b)
        let second = query()
        expect(second.sessionID == first.sessionID && second.processID == first.processID, "track changes keep the control target")
        expect(!player.isPlaying && player.currentURL == b, "fixture track change remains silent")
        player.stop()
        let stopped = query()
        expect(!stopped.hasItem && stopped.sessionID == nil, "stop clears the live playback session")
        expect(deliver(request(.play, target: first)).accepted == false, "old session cannot restart stopped playback")
        expect(!center.handle(["type": "unrelated-file-message"]), "file messages are not consumed")
        var malformed: [String: Any] = [:]
        expect(center.handle([PlaybackControlWire.key: Data([0])], reply: { malformed = $0 }), "malformed playback stays isolated")
        expect(malformed["playbackAccepted"] as? Bool == false, "malformed request rejected")
        print("PASS: \(checks) silent native playback-control assertions")
    }
}
