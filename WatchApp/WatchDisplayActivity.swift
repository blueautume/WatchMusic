import Foundation

/// A public Foundation request, not an acknowledgement that watchOS keeps the
/// display lit. User settings and the system's display policy still apply.
@MainActor
final class WatchDisplayActivity {
    private final class Lease {
        let token: any NSObjectProtocol
        init() {
            token = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled,
                                                         reason: "WatchMusic charging or music transfer")
        }
        deinit { ProcessInfo.processInfo.endActivity(token) }
    }

    private var state = WatchDisplayActivityState()
    private var lease: Lease?
    private var inputs = WatchDisplayActivityState.Inputs(isCharging: false, isReceiving: false, isFrontmost: false)
    #if DEBUG
    private var events: [[String: Any]]?
    #endif

    func update(isCharging: Bool, isReceiving: Bool, isFrontmost: Bool) {
        let next = WatchDisplayActivityState.Inputs(isCharging: isCharging, isReceiving: isReceiving, isFrontmost: isFrontmost)
        guard next != inputs else { return }
        inputs = next
        switch state.update(next) {
        case .begin:
            lease = Lease()
            record("request-began")
        case .end:
            lease = nil
            record("request-ended")
        case nil:
            record("state-changed")
        }
    }

    func stop() {
        update(isCharging: inputs.isCharging, isReceiving: inputs.isReceiving, isFrontmost: false)
    }

    private func record(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-lan-record-lifecycle") else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lan-display-activity.json")
        if events == nil {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
               size.int64Value <= 1_048_576, let data = try? Data(contentsOf: url),
               let restored = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                events = Array(restored.suffix(255))
            } else { events = [] }
        }
        events?.append(["event": event, "timestamp": Date().timeIntervalSince1970,
                        "charging": inputs.isCharging, "receiving": inputs.isReceiving,
                        "frontmost": inputs.isFrontmost, "requested": state.isRequested,
                        "evidence": "request-only"])
        if let events, events.count > 256 { self.events = Array(events.suffix(256)) }
        if let events, let data = try? JSONSerialization.data(withJSONObject: events) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        #endif
    }
}
