import Foundation
import ImageIO
import Combine
import AVFoundation

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
        // A visible countdown reads the deadline locally; it must never invalidate
        // every player observer (including open SwiftUI menus) on a clock tick.
        try await Task.sleep(for: .milliseconds(700))
        var changes = 0
        let observation = engine.objectWillChange.sink { changes += 1 }
        let countdownDeadline = Date().addingTimeInterval(2)
        engine.setSleepTimer(until: countdownDeadline)
        let beforeCountdown = engine.sleepRemaining ?? 0
        changes = 0
        try await Task.sleep(for: .milliseconds(350))
        try check(changes == 0, "audio clock and countdown never publish periodic object changes")
        try check((engine.sleepRemaining ?? beforeCountdown) < beforeCountdown - 0.2, "countdown getter follows its deadline without publishing")
        engine.setSleepTimer(until: Date().addingTimeInterval(0.05))
        let replacementDeadline = Date().addingTimeInterval(1)
        engine.setSleepTimer(until: replacementDeadline)
        try await Task.sleep(for: .milliseconds(150))
        try check(engine.sleepTimerDeadline == replacementDeadline, "replacing timer cancels the old deadline task")
        engine.setSleepTimer(minutes: nil)
        changes = 0
        try await Task.sleep(for: .milliseconds(150))
        try check(changes == 0 && engine.sleepRemaining == nil, "cancelled timer leaves no periodic work")
        engine.setSleepTimer(until: Date().addingTimeInterval(0.05))
        try await waitUntil("sleep deadline pauses and clears itself", timeout: 1) {
            engine.sleepTimerDeadline == nil && !engine.isPlaying
        }
        observation.cancel()
        engine.savePlaybackPosition()
        let savedAfterLifecycle = defaults.data(forKey: "player.session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        try check(abs((savedAfterLifecycle?.elapsed ?? 0) - engine.elapsed) < 0.15, "lifecycle save persists the decoder position")
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

        // Drive the real delegate/state flow while holding route activation. The
        // decoder reads a real local file but never opens or plays an audio output.
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "player.session")
        var completionDecoder: SilentCompletionDecoder?
        var activations: [@MainActor (Bool, String?) -> Void] = []
        player = MusicPlayer(makeAudioPlayer: { url in
            let decoder = try SilentCompletionDecoder(contentsOf: url)
            completionDecoder = decoder
            return decoder
        }, activateAudioSession: { activations.append($0) })
        guard let completionEngine = player, let decoder = completionDecoder else {
            throw ProbeError.failure("completion transition player")
        }
        completionEngine.resume()
        try check(activations.count == 1 && completionEngine.isPreparing, "resume waits for route activation")
        activations.removeFirst()(true, nil)
        try check(completionEngine.isPlaying, "successful activation marks decoder playing")
        completionEngine.play(b, in: [a, b, c])
        try check(activations.count == 1 && completionEngine.isPreparing, "requested next track waits for its route")
        decoder.stop()
        completionEngine.audioPlayerDidFinishPlaying(decoder, successfully: true)
        try await waitUntil("finishing old track publishes stopped state during pending activation", timeout: 1) {
            !completionEngine.isPlaying
        }
        try check(completionEngine.isPreparing && completionEngine.currentURL == a, "completion preserves pending user track request")
        try check(abs(completionEngine.elapsed - completionEngine.duration) < 0.15, "completion preserves the ended position")
        activations.removeFirst()(false, "模拟路由不可用")
        try check(!completionEngine.isPlaying && !completionEngine.isPreparing, "failed pending route cannot leave playback running")
        let completedSnapshot = defaults.data(forKey: "player.session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        try check(abs((completedSnapshot?.elapsed ?? 0) - completionEngine.duration) < 0.15, "completed position is saved before a pending route can fail")
        completionEngine.resume()
        activations.removeFirst()(true, nil)
        try check(completionEngine.isPlaying && completionEngine.elapsed < 0.15, "resuming an ended track starts from its beginning")
        decoder.stop()
        completionEngine.audioPlayerDidFinishPlaying(decoder, successfully: true)
        try await waitUntil("natural completion marks stopped while advancing the queue", timeout: 1) {
            !completionEngine.isPlaying && completionEngine.isPreparing
        }
        try check(activations.count == 1, "natural completion requests only one next route")
        activations.removeFirst()(false, "模拟续播路由不可用")
        try check(!completionEngine.isPlaying && !completionEngine.isPreparing, "failed automatic next route remains stopped")
        completionEngine.resume()
        activations.removeFirst()(true, nil)
        completionEngine.play(b, in: [a, b, c])
        decoder.stop()
        activations.removeFirst()(false, "模拟旧输出停止")
        try check(!completionEngine.isPlaying, "activation failure samples a stopped output even without a finish callback")
        completionEngine.resume()
        activations.removeFirst()(true, nil)
        completionEngine.seek(to: 6)
        completionEngine.play(b, in: [a, b, c])
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await waitUntil("audio service reset clears a pending route activation", timeout: 1) {
            !completionEngine.isPreparing && !completionEngine.isPlaying
        }
        activations.removeFirst()(true, nil)
        try check(completionDecoder === decoder && !completionEngine.isPlaying, "stale activation cannot start a new decoder after audio services reset")
        completionEngine.resume()
        try check(activations.count == 1 && abs(completionEngine.elapsed - 6) < 0.15, "service recovery recreates the paused decoder at its saved position")
        activations.removeFirst()(true, nil)
        try check(completionEngine.isPlaying && abs(completionEngine.elapsed - 6) < 0.15, "service recovery resumes from the saved position")
        completionEngine.stop()
        player = nil
        print("COMPLETION_STATE_PASS")

        // Output selection returns focus to its caller on every completion path,
        // without a timer or an actual audio route in this probe.
        var outputCallbacks: [@MainActor (Bool, String?) -> Void] = []
        var outputCompletions = 0
        let outputEngine = MusicPlayer(makeAudioPlayer: { try SilentCompletionDecoder(contentsOf: $0) },
                                       activateAudioSession: { outputCallbacks.append($0) })
        outputEngine.requestAudioOutput { outputCompletions += 1 }
        try check(outputCallbacks.count == 1 && outputCompletions == 0,
                  "output selection waits for native session activation completion")
        outputCallbacks.removeFirst()(false, "Output test failure")
        try check(outputCompletions == 1 && outputEngine.errorMessage == "Output test failure",
                  "failed output selection reports the error and returns focus once")
        outputEngine.errorMessage = nil
        outputEngine.requestAudioOutput { outputCompletions += 1 }
        outputCallbacks.removeFirst()(true, nil)
        try check(outputCompletions == 2 && outputEngine.errorMessage == nil,
                  "successful output selection returns focus once")
        outputEngine.play(a, in: [a])
        try check(outputEngine.isPreparing && outputCallbacks.count == 1, "fixture holds a pending playback activation")
        outputEngine.requestAudioOutput { outputCompletions += 1 }
        try check(outputCompletions == 3 && outputCallbacks.count == 1,
                  "busy playback rejects output selection and immediately returns focus")
        outputCallbacks.removeFirst()(false, "Held test activation")
        outputEngine.stop()
        do {
            let releasedEngine = MusicPlayer(makeAudioPlayer: { try SilentCompletionDecoder(contentsOf: $0) },
                                             activateAudioSession: { outputCallbacks.append($0) })
            releasedEngine.requestAudioOutput { outputCompletions += 1 }
        }
        try check(outputCallbacks.count == 1, "output activation can outlive its player")
        outputCallbacks.removeFirst()(true, nil)
        try check(outputCompletions == 4, "late output completion returns focus even after the player is released")
        print("OUTPUT_FOCUS_COMPLETION_PASS")

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

/// Deterministic delegate fixture: real duration/seeking, no audio-device use.
private final class SilentCompletionDecoder: AVAudioPlayer, @unchecked Sendable {
    private var playbackActive = false
    override var isPlaying: Bool { playbackActive }
    override func prepareToPlay() -> Bool { true }
    override func play() -> Bool { playbackActive = true; return true }
    override func pause() { playbackActive = false }
    override func stop() { playbackActive = false }
}
