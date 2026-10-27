import Foundation

enum PlaybackControlDevice: String, Codable { case phone, watch }
enum PlaybackControlAction: String, Codable { case play, pause, previous, next }

/// Deliberately contains no media name, URL, artwork, position, or duration.
struct PlaybackControlState: Codable, Equatable {
    let processID: String
    let sessionID: String?
    let revision: Int64
    let hasItem: Bool
    let isPlaying: Bool
    let isPreparing: Bool

    var isValid: Bool {
        UUID(uuidString: processID) != nil && revision >= 0 &&
        (hasItem ? sessionID.flatMap(UUID.init(uuidString:)) != nil : sessionID == nil) &&
        (!isPlaying || hasItem) && (!isPreparing || hasItem)
    }
}

struct PlaybackControlCommand: Codable, Equatable {
    let targetProcessID: String
    let targetSessionID: String
    let action: PlaybackControlAction
    let issuedAt: Date
}

struct PlaybackControlEnvelope: Codable {
    enum Kind: String, Codable { case state, query, command, result }
    let version: Int
    let kind: Kind
    let sender: PlaybackControlDevice
    let requestID: String
    var state: PlaybackControlState?
    var command: PlaybackControlCommand?
    var accepted: Bool?
}

enum PlaybackControlWire {
    static let key = "playbackControl"

    static func message(_ envelope: PlaybackControlEnvelope) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(envelope), data.count <= 8_192 else { return nil }
        return [key: data]
    }

    static func decode(_ message: [String: Any], from expected: PlaybackControlDevice) -> PlaybackControlEnvelope? {
        guard let data = message[key] as? Data, data.count <= 8_192,
              let value = try? JSONDecoder().decode(PlaybackControlEnvelope.self, from: data),
              value.version == 1, value.sender == expected, UUID(uuidString: value.requestID) != nil,
              value.state?.isValid != false else { return nil }
        return value
    }
}

/// Only a response to a fresh live request may replace the peer process. Old
/// unsolicited packets cannot resurrect an earlier app instance after restart.
struct PlaybackPeerStateStore {
    private(set) var state: PlaybackControlState?
    private(set) var isConfirmed = false
    private var retiredProcesses: [String] = []
    private var pendingStates: [String: PlaybackControlState] = [:]

    @discardableResult mutating func confirm(_ next: PlaybackControlState) -> Bool {
        guard next.isValid, !retiredProcesses.contains(next.processID) else { return false }
        var newest = next
        if let current = state {
            if next.processID == current.processID {
                if current.revision > newest.revision { newest = current }
            } else {
                retiredProcesses.append(current.processID)
                if retiredProcesses.count > 16 { retiredProcesses.removeFirst() }
            }
        }
        if let pending = pendingStates[next.processID], pending.revision > newest.revision { newest = pending }
        pendingStates = [:]
        state = newest; isConfirmed = true
        return true
    }

    @discardableResult mutating func update(_ next: PlaybackControlState) -> Bool {
        guard next.isValid, !retiredProcesses.contains(next.processID) else { return false }
        guard let current = state, next.processID == current.processID else {
            if pendingStates[next.processID].map({ $0.revision < next.revision }) ?? true {
                if pendingStates.count >= 4 { pendingStates = [:] }
                pendingStates[next.processID] = next
            }
            return false
        }
        guard next.revision >= current.revision else { return false }
        state = next
        return true
    }

    mutating func disconnect() { isConfirmed = false; pendingStates = [:] }
}

struct PlaybackCommandGate {
    enum Decision: Equatable { case execute, duplicate, reject }
    private var completedIDs: [String] = []
    private var completedCommands: [String: PlaybackControlCommand] = [:]

    mutating func evaluate(requestID: String, command: PlaybackControlCommand,
                           current: PlaybackControlState, now: Date = Date()) -> Decision {
        guard let canonicalID = UUID(uuidString: requestID)?.uuidString else { return .reject }
        if let completed = completedCommands[canonicalID] { return completed == command ? .duplicate : .reject }
        let age = now.timeIntervalSince(command.issuedAt)
        guard age.isFinite, age >= -2, age <= 4, current.hasItem,
              (!current.isPreparing || command.action == .pause),
              command.targetProcessID == current.processID,
              command.targetSessionID == current.sessionID else { return .reject }
        completedIDs.append(canonicalID)
        completedCommands[canonicalID] = command
        if completedIDs.count > 512 { completedCommands.removeValue(forKey: completedIDs.removeFirst()) }
        return .execute
    }
}
