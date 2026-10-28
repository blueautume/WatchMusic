import Foundation

@main struct PlaybackControlProtocolTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        checks += 1
    }
    static func main() throws {
        let process = UUID().uuidString, session = UUID().uuidString
        let now = Date()
        func state(_ revision: Int64, processID: String = process, sessionID: String? = session,
                   hasItem: Bool = true, playing: Bool = false, preparing: Bool = false) -> PlaybackControlState {
            PlaybackControlState(processID: processID, sessionID: sessionID, revision: revision,
                                 hasItem: hasItem, isPlaying: playing, isPreparing: preparing)
        }
        func command(_ action: PlaybackControlAction = .next, processID: String = process,
                     sessionID: String = session, date: Date = now) -> PlaybackControlCommand {
            PlaybackControlCommand(targetProcessID: processID, targetSessionID: sessionID, action: action, issuedAt: date)
        }
        let valid = state(1)
        expect(valid.isValid, "valid state")
        expect(!state(-1).isValid, "negative version rejected")
        expect(!state(1, processID: "wrong").isValid, "bad process rejected")
        expect(!state(1, sessionID: nil).isValid, "item requires a session")
        expect(!state(1, sessionID: nil, hasItem: false, playing: true).isValid, "cannot play without an item")
        expect(state(1, sessionID: nil, hasItem: false).isValid, "idle state")

        var gate = PlaybackCommandGate()
        let id = UUID().uuidString
        expect(gate.evaluate(requestID: id, command: command(), current: valid, now: now) == .execute, "first next executes")
        expect(gate.evaluate(requestID: id, command: command(), current: valid, now: now) == .duplicate, "duplicate next never executes twice")
        expect(gate.evaluate(requestID: id.lowercased(), command: command(), current: valid, now: now) == .duplicate, "UUID case cannot bypass deduplication")
        expect(gate.evaluate(requestID: id, command: command(.pause), current: valid, now: now) == .reject, "reused ID with different command rejected")
        for action in [PlaybackControlAction.play, .pause, .previous, .next] {
            expect(gate.evaluate(requestID: UUID().uuidString, command: command(action), current: valid, now: now) == .execute, "four basic actions")
        }
        expect(gate.evaluate(requestID: UUID().uuidString, command: command(processID: UUID().uuidString), current: valid, now: now) == .reject, "old process cannot control new app")
        expect(gate.evaluate(requestID: UUID().uuidString, command: command(sessionID: UUID().uuidString), current: valid, now: now) == .reject, "old playback session rejected")
        expect(gate.evaluate(requestID: UUID().uuidString, command: command(date: now.addingTimeInterval(-4.1)), current: valid, now: now) == .reject, "late command expires")
        expect(gate.evaluate(requestID: UUID().uuidString, command: command(date: now.addingTimeInterval(3)), current: valid, now: now) == .reject, "invalid future timestamp rejected")
        expect(gate.evaluate(requestID: "invalid", command: command(), current: valid, now: now) == .reject, "invalid command identity rejected")
        expect(gate.evaluate(requestID: UUID().uuidString, command: command(), current: state(2, preparing: true), now: now) == .reject, "skip does not race route activation")
        expect(gate.evaluate(requestID: UUID().uuidString, command: command(.pause), current: state(2, preparing: true), now: now) == .execute, "pause can cancel pending activation")
        expect(gate.evaluate(requestID: UUID().uuidString, command: command(.play), current: state(2, sessionID: nil, hasItem: false), now: now) == .reject, "remote never chooses a local song")

        var peer = PlaybackPeerStateStore()
        expect(!peer.update(state(3, playing: true)), "unsolicited new process needs confirmation")
        expect(peer.state == nil && !peer.isConfirmed, "unconfirmed process not displayed as current")
        expect(peer.confirm(state(1)), "live response confirms process")
        expect(peer.state?.revision == 3 && peer.state?.isPlaying == true, "newer in-flight state wins over query response")
        expect(!peer.update(state(2)), "old update rejected")
        expect(peer.state?.revision == 3, "old update cannot rewind state")
        expect(peer.confirm(state(1)) && peer.state?.revision == 3, "query confirmation never downgrades latest state")
        peer.disconnect()
        expect(!peer.isConfirmed && peer.state?.hasItem == true, "disconnect disables controls while retaining last visual state")
        expect(peer.update(state(4)), "same known process update retained during reconnect")
        expect(!peer.isConfirmed, "state update alone does not authorize controls after reconnect")
        expect(peer.confirm(state(3)) && peer.isConfirmed && peer.state?.revision == 4, "live reconnect query confirms latest revision")
        let fresh = UUID().uuidString
        expect(!peer.update(state(2, processID: fresh)), "replacement process pending until handshake")
        expect(peer.confirm(state(1, processID: fresh)), "replacement process may restart revision numbering")
        expect(peer.state?.processID == fresh && peer.state?.revision == 2, "highest replacement state retained")
        expect(!peer.update(state(100)) && !peer.confirm(state(100)), "retired process cannot resurrect")

        let envelope = PlaybackControlEnvelope(version: 1, kind: .state, sender: .phone,
                                               requestID: UUID().uuidString, state: valid)
        let message = PlaybackControlWire.message(envelope)!
        expect(PlaybackControlWire.decode(message, from: .phone)?.state == valid, "property-list data roundtrip")
        expect(PlaybackControlWire.decode(message, from: .watch) == nil, "wrong direction rejected")
        expect(PlaybackControlWire.decode([PlaybackControlWire.key: Data(repeating: 0, count: 8_193)], from: .phone) == nil, "payload bound")
        let bytes = message[PlaybackControlWire.key] as! Data
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let stateJSON = json["state"] as! [String: Any]
        expect(Set(stateJSON.keys) == Set(["processID", "sessionID", "revision", "hasItem", "isPlaying", "isPreparing"]), "wire contains only playback flags and routing identifiers")
        print("PASS: \(checks) playback control protocol assertions")
    }
}
