import Foundation

/// Opt-in simulator evidence for the native control's actual lifecycle.
/// No trace is produced in Release builds or on a physical Watch.
@MainActor
enum WatchCrownDiagnostics {
    #if DEBUG && targetEnvironment(simulator)
    private static var hasRequestedFocus = false
    private static var focusObserver: AsyncStream<Void>.Continuation?
    #endif

    static func record(_ event: String, focused: Bool? = nil, playing: Bool? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("-preview-crown-trace") else { return }
        if event == "made" { hasRequestedFocus = false }
        if event == "focus-requested" {
            hasRequestedFocus = true
            focusObserver?.yield(())
            focusObserver?.finish()
            focusObserver = nil
        }
        var entry: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970]
        if let focused { entry["focused"] = focused }
        if let playing { entry["playing"] = playing }
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent(".watch-crown-trace.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else { try? data.write(to: url, options: .atomic) }
        #endif
    }

    static func waitForInitialFocusRequest() async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if hasRequestedFocus { return true }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        focusObserver = continuation
        defer { focusObserver?.finish(); focusObserver = nil }
        for await _ in stream { return !Task.isCancelled }
        #endif
        return false
    }
}
