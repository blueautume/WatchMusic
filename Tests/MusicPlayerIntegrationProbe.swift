import Foundation
import ImageIO

/// Standalone simulator integration test. It restores local files without
/// activating playback or an audio output route, and restores preferences after
/// the test. It never launches or drives the app's user interface.
@main
struct MusicPlayerIntegrationProbe {
    @MainActor static var assertions = 0

    @MainActor
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeError.failure(message) }
        assertions += 1
    }

    @MainActor
    static func waitUntil(_ message: String, timeout: Double = 8, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try check(condition(), message)
    }

    private struct Session: Codable { let paths: [String]; let current: String; let elapsed: Double }

    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 1 else { throw ProbeError.failure("Usage: MusicPlayerIntegrationProbe AUDIO [EMBEDDED_MP3 EMBEDDED_FLAC]") }
            try await run(arguments)
            print("PASS: \(assertions) native player integration assertions")
        } catch {
            FileHandle.standardError.write(Data("PLAYER_PROBE_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func run(_ arguments: [String]) async throws {
        let manager = FileManager.default
        let defaults = UserDefaults.standard
        let keys = ["player.session", "player.mode", "player.rate", "player.volume"]
        var backup: [String: Any] = [:]
        for key in keys { if let value = defaults.object(forKey: key) { backup[key] = value } }
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folderName = "MusicPlayerIntegrationProbe-" + UUID().uuidString
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var player: MusicPlayer?
        defer {
            player?.stop()
            player = nil
            for key in keys {
                if let value = backup[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.synchronize()
            try? manager.removeItem(at: folder)
        }
        let source = URL(fileURLWithPath: arguments[0])
        let a = folder.appendingPathComponent("A." + source.pathExtension)
        let b = folder.appendingPathComponent("B." + source.pathExtension)
        let c = folder.appendingPathComponent("C." + source.pathExtension)
        for audio in [a, b, c] {
            try manager.copyItem(at: source, to: audio)
        }
        func relative(_ url: URL) -> String { folderName + "/" + url.lastPathComponent }
        let snapshot = Session(paths: [a, b, c].map(relative), current: relative(a), elapsed: 5)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "player.session")
        defaults.set(PlaybackMode.repeatAll.rawValue, forKey: "player.mode")
        defaults.set(1.25, forKey: "player.rate")
        defaults.set(Float(0.7), forKey: "player.volume")
        player = MusicPlayer()
        guard let engine = player else { throw ProbeError.failure("player initialization") }
        try check(engine.currentURL == a, "relative-path session restores current track")
        try check(engine.queue == [a, b, c], "session restores queue order")
        try check(abs(engine.elapsed - 5) < 0.15, "session restores elapsed position")
        try check(abs(engine.duration - 16) < 0.15, "decoder exposes duration")
        try check(!engine.isPlaying && !engine.isPreparing, "restoration never starts playback or route activation")
        try check(engine.mode == .repeatAll && engine.playbackRate == 1.25, "preferences restored")
        try check(abs(engine.volume - 0.7) < 0.01, "volume preference restored")
        engine.seek(to: 8)
        try check(abs(engine.elapsed - 8) < 0.15, "seek changes paused decoder position")
        engine.seek(to: -100)
        try check(engine.elapsed == 0, "seek lower bound")
        engine.seek(to: .infinity)
        try check(engine.elapsed == 0, "nonfinite seek ignored")
        engine.seek(to: 10_000)
        try check(abs(engine.elapsed - engine.duration) < 0.15, "seek upper bound")
        engine.seek(to: 5)
        engine.setSleepTimer(minutes: 15)
        try check(abs((engine.sleepRemaining ?? 0) - 900) < 1, "sleep timer schedules while paused")
        engine.setSleepTimer(minutes: nil)
        try check(engine.sleepRemaining == nil, "sleep timer cancellation")
        engine.moveQueueItems(from: IndexSet(integer: 2), to: 0)
        try check(engine.queue == [c, a, b] && engine.currentURL == a, "queue reorder preserves current track")
        engine.removeQueueItem(at: 2)
        try check(engine.queue == [c, a] && engine.currentURL == a && !engine.isPlaying, "noncurrent removal preserves paused current track")
        engine.removeQueueItem(at: -1)
        engine.removeQueueItem(at: 999)
        try check(engine.queue == [c, a], "invalid queue removals are no-ops")
        engine.removeQueueItem(at: 1)
        try check(engine.queue == [c] && engine.currentURL == c && !engine.isPlaying, "removing paused current item loads next without sound")
        try check(engine.elapsed < 0.15, "next paused track resets position")
        // Removing the last item must invalidate asynchronous metadata work.
        engine.removeQueueItem(at: 0)
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(engine.currentURL == nil && engine.queue.isEmpty && !engine.isPlaying, "last queue removal stops player")
        try check(engine.artworkData == nil, "canceled metadata cannot restore stopped-track content")
        try check([a, b, c].allSatisfy { manager.fileExists(atPath: $0.path) }, "queue edits never delete audio files")
        engine.stop()
        player = nil
        print("CORE_PLAYER_PASS: \(assertions) restore/seek/queue assertions")

        // Optional real fixtures verify bounded embedded artwork on both platforms.
        for argument in arguments.dropFirst() {
            let fixture = URL(fileURLWithPath: argument)
            let audio = folder.appendingPathComponent("embedded-" + fixture.lastPathComponent)
            try manager.copyItem(at: fixture, to: audio)
            let embeddedSnapshot = Session(paths: [relative(audio)], current: relative(audio), elapsed: 5)
            defaults.set(try JSONEncoder().encode(embeddedSnapshot), forKey: "player.session")
            player = MusicPlayer()
            guard let embedded = player else { throw ProbeError.failure("embedded fixture player") }
            try await waitUntil("embedded \(fixture.pathExtension) title and artwork load", timeout: 10) {
                embedded.artworkData != nil && embedded.title != audio.deletingPathExtension().lastPathComponent
            }
            try check(embedded.currentURL == audio && !embedded.isPlaying && !embedded.isPreparing, "embedded fixture restoration remains silent")
            try check(embedded.title != audio.deletingPathExtension().lastPathComponent, "embedded title metadata loads")
            try check(embedded.artist != "本地音乐" && !embedded.artist.isEmpty, "embedded artist metadata loads")
            guard let imageData = embedded.artworkData,
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let cover = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ProbeError.failure("embedded cover is not an image") }
            try check(cover.width <= 1_024 && cover.height <= 1_024, "embedded cover is bounded for watch memory")
            print("EMBEDDED_ARTWORK_PASS \(fixture.pathExtension)")
            embedded.stop()
            player = nil
        }
    }

    private enum ProbeError: LocalizedError {
        case failure(String)
        var errorDescription: String? { if case .failure(let message) = self { return message }; return nil }
    }
}
