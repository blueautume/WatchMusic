import Foundation
import ImageIO
import Combine
import AVFoundation
import MediaPlayer

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
        let commands = MPRemoteCommandCenter.shared()
        let remoteCommands = [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                              commands.nextTrackCommand, commands.previousTrackCommand,
                              commands.skipForwardCommand, commands.skipBackwardCommand,
                              commands.seekForwardCommand, commands.seekBackwardCommand,
                              commands.changePlaybackPositionCommand]
        let commandStates = remoteCommands.map(\.isEnabled)
        defer {
            for (command, wasEnabled) in zip(remoteCommands, commandStates) { command.isEnabled = wasEnabled }
        }
        // Deliberately simulate stale interval controls, rather than depending
        // on the command center's default state in a particular OS release.
        commands.skipForwardCommand.isEnabled = true
        commands.skipBackwardCommand.isEnabled = true
        commands.seekForwardCommand.isEnabled = true
        commands.seekBackwardCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        var restoredDecoder: AVAudioPlayer?
        var systemInfo: [String: Any]?
        player = MusicPlayer(makeAudioPlayer: { url in
            let decoder = try AVAudioPlayer(contentsOf: url)
            restoredDecoder = decoder
            return decoder
        }, publishNowPlayingInfo: { systemInfo = $0 })
        guard let engine = player else { throw ProbeError.failure("player initialization") }
        try check(!commands.skipForwardCommand.isEnabled && !commands.skipBackwardCommand.isEnabled,
                  "system playback controls disable interval skips instead of exposing fifteen-second buttons")
        try check(!commands.seekForwardCommand.isEnabled && !commands.seekBackwardCommand.isEnabled,
                  "continuous seek commands do not replace track navigation")
        try check(commands.nextTrackCommand.isEnabled && commands.previousTrackCommand.isEnabled,
                  "system playback controls enable previous and next tracks")
        try check(commands.playCommand.isEnabled && commands.pauseCommand.isEnabled && commands.togglePlayPauseCommand.isEnabled,
                  "system playback controls retain play and pause actions")
        try check(commands.changePlaybackPositionCommand.isEnabled,
                  "system timeline scrubbing remains available independently of track buttons")
        try check(engine.currentURL == a, "relative-path session restores current track")
        try check(engine.queue == [a, b, c], "session restores queue order")
        try check(abs(engine.elapsed - 5) < 0.15, "session restores elapsed position")
        try check(abs(engine.duration - 16) < 0.15, "decoder exposes duration")
        try check(!engine.isPlaying && !engine.isPreparing, "restoration never starts playback or route activation")
        try check(engine.mode == .repeatAll && engine.playbackRate == 1.25, "preferences restored")
        try check(restoredDecoder?.volume == 1, "legacy reduced app gain cannot attenuate restored audio")
        try check(defaults.object(forKey: "player.volume") == nil, "legacy app gain preference is removed")
        try check((systemInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0,
                  "restored system controls describe paused playback")
        try check(systemInfo?[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 3
                  && systemInfo?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 0,
                  "system controls receive restored queue context")
        try check(systemInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == relative(a),
                  "system media identity remains stable without exposing a sandbox URL")
        engine.seek(to: 8)
        try check(abs(engine.elapsed - 8) < 0.15, "seek changes paused decoder position")
        try check(abs((systemInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1) - 8) < 0.15,
                  "system timeline follows seeking without a recurring timer")
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
        try check(systemInfo?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 1,
                  "system queue index follows a reorder that leaves the song unchanged")
        engine.removeQueueItem(at: 2)
        try check(engine.queue == [c, a] && engine.currentURL == a && !engine.isPlaying, "noncurrent removal preserves paused current track")
        try check(systemInfo?[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 2,
                  "system queue count follows noncurrent removal")
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
        try check(systemInfo == nil, "last removal clears system controls and canceled metadata cannot republish them")
        try check([a, b, c].allSatisfy { manager.fileExists(atPath: $0.path) }, "queue edits never delete audio files")
        engine.stop()
        player = nil
        print("CORE_PLAYER_PASS: \(assertions) restore/seek/queue assertions")

        // A previously muted app must also recover when its slider disappears.
        // Inspect the real decoder without activating a route or playing audio.
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "player.session")
        defaults.set(Float(0), forKey: "player.volume")
        var migratedDecoder: AVAudioPlayer?
        let migratedEngine = MusicPlayer(makeAudioPlayer: { url in
            let decoder = try AVAudioPlayer(contentsOf: url)
            migratedDecoder = decoder
            return decoder
        })
        try check(migratedEngine.currentURL == a && !migratedEngine.isPlaying,
                  "legacy mute migration preserves silent session restoration")
        try check(migratedDecoder?.volume == 1, "legacy mute cannot suppress the system-controlled volume")
        try check(defaults.object(forKey: "player.volume") == nil, "legacy mute is removed from preferences")
        migratedEngine.stop()

        // Drive the real delegate/state flow while holding route activation. The
        // decoder reads a real local file but never opens or plays an audio output.
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "player.session")
        var completionDecoder: SilentCompletionDecoder?
        var activations: [@MainActor (Bool, String?) -> Void] = []
        var completionInfo: [String: Any]?
        player = MusicPlayer(makeAudioPlayer: { url in
            let decoder = try SilentCompletionDecoder(contentsOf: url)
            completionDecoder = decoder
            return decoder
        }, activateAudioSession: { activations.append($0) }, publishNowPlayingInfo: { completionInfo = $0 })
        guard let completionEngine = player, let decoder = completionDecoder else {
            throw ProbeError.failure("completion transition player")
        }
        completionEngine.resume()
        try check(activations.count == 1 && completionEngine.isPreparing, "resume waits for route activation")
        activations.removeFirst()(true, nil)
        try check(completionEngine.isPlaying, "successful activation marks decoder playing")
        try check((completionInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 1.25,
                  "successful playback publishes its real rate to system controls")
        completionEngine.pause()
        try check((completionInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0,
                  "pause immediately publishes a stopped system timeline")
        completionEngine.resume()
        activations.removeFirst()(true, nil)
        completionEngine.play(b, in: [a, b, c])
        try check(activations.count == 1 && completionEngine.isPreparing, "requested next track waits for its route")
        decoder.stop()
        completionEngine.audioPlayerDidFinishPlaying(decoder, successfully: true)
        try await waitUntil("finishing old track publishes stopped state during pending activation", timeout: 1) {
            !completionEngine.isPlaying
        }
        try check(completionEngine.isPreparing && completionEngine.currentURL == a, "completion preserves pending user track request")
        try check(abs(completionEngine.elapsed - completionEngine.duration) < 0.15, "completion preserves the ended position")
        try check((completionInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0
                  && abs((completionInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1)
                         - completionEngine.duration) < 0.15,
                  "completion publishes the ended position while the next route is still pending")
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
        try check((completionInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0,
                  "audio service reset cannot leave the system card reporting active playback")
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

        try await runEnergyLifecycleTests(tracks: [a, b, c], snapshot: snapshot)

        // Optional real fixtures verify bounded embedded artwork on both platforms.
        for argument in arguments.dropFirst() {
            let fixture = URL(fileURLWithPath: argument)
            let audio = folder.appendingPathComponent("embedded-" + fixture.lastPathComponent)
            try manager.copyItem(at: fixture, to: audio)
            let embeddedSnapshot = Session(paths: [relative(audio)], current: relative(audio), elapsed: 5)
            defaults.set(try JSONEncoder().encode(embeddedSnapshot), forKey: "player.session")
            var embeddedSystemInfo: [String: Any]?
            player = MusicPlayer(makeAudioPlayer: { try AVAudioPlayer(contentsOf: $0) },
                                 publishNowPlayingInfo: { embeddedSystemInfo = $0 })
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
            guard let artwork = embeddedSystemInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else {
                throw ProbeError.failure("embedded system artwork")
            }
            embedded.seek(to: 6)
            try check((embeddedSystemInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) === artwork,
                      "seeking reuses the unchanged system artwork object")
            embedded.setRate(1.5)
            try check((embeddedSystemInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) === artwork,
                      "speed updates reuse the unchanged system artwork object")
            embedded.savePlaybackPosition()
            try check((embeddedSystemInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) === artwork,
                      "lifecycle publishing reuses the unchanged system artwork object")
            print("EMBEDDED_ARTWORK_PASS \(fixture.pathExtension)")
            embedded.stop()
            player = nil
        }
    }

    @MainActor
    private static func runEnergyLifecycleTests(tracks: [URL], snapshot: Session) async throws {
        let defaults = UserDefaults.standard
        let a = tracks[0], b = tracks[1]
        func fixture() throws -> (MusicPlayer, PlayerEnergyState) {
            defaults.set(try JSONEncoder().encode(snapshot), forKey: "player.session")
            defaults.set(1.25, forKey: "player.rate")
            defaults.set(PlaybackMode.repeatAll.rawValue, forKey: "player.mode")
            let state = PlayerEnergyState()
            let engine = MusicPlayer(makeAudioPlayer: { url in
                if state.rejectDecoderCreation { throw NSError(domain: "EnergyProbe", code: 1) }
                let decoder = try SilentCompletionDecoder(contentsOf: url)
                state.decoders.append(decoder)
                return decoder
            }, activateAudioSession: { state.activations.append($0) },
               deactivateAudioSession: {
                   state.deactivations += 1
                   if state.failedDeactivationsRemaining > 0 {
                       state.failedDeactivationsRemaining -= 1
                       throw NSError(domain: "EnergyProbe", code: 2)
                   }
                   state.sessionIsActive = false
               }, publishNowPlayingInfo: { state.systemInfo = $0 })
            return (engine, state)
        }
        func finish(_ state: PlayerEnergyState, at index: Int = 0, success: Bool = true) throws {
            try check(state.activations.indices.contains(index), "expected held audio activation")
            let callback = state.activations.remove(at: index)
            if success { state.sessionIsActive = true }
            callback(success, success ? nil : "Energy probe activation failure")
        }
        func pausedMedia(_ engine: MusicPlayer, _ state: PlayerEnergyState, position: Double = 6) throws {
            try check(engine.currentURL == a && engine.queue == tracks,
                      "energy cleanup preserves the selected song and queue")
            try check(abs(engine.elapsed - position) < 0.15 && engine.playbackRate == 1.25,
                      "energy cleanup preserves position and playback speed")
            try check(state.systemInfo?[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == tracks.count
                      && (state.systemInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0,
                      "energy cleanup retains a paused system media card and queue")
            try check(abs((state.systemInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1) - position) < 0.15,
                      "energy cleanup retains the system media position")
            try check(MPRemoteCommandCenter.shared().playCommand.isEnabled,
                      "released background audio remains available to system play controls")
        }

        // Foreground pause remains ready for Crown/output interaction. Entering
        // the background releases buffers/session while retaining resumable media.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            guard let decoder = state.decoders.first else { throw ProbeError.failure("energy decoder") }
            engine.resume()
            try finish(state)
            engine.seek(to: 6)
            let prepared = decoder.prepareCount
            let stops = decoder.stopCount
            engine.pause()
            try check(decoder.stopCount == stops && state.deactivations == 0 && state.sessionIsActive,
                      "foreground short pause retains prepared audio and session")
            try pausedMedia(engine, state)
            engine.setApplicationInBackground(true)
            try check(decoder.stopCount == stops + 1 && state.deactivations == 1 && !state.sessionIsActive,
                      "paused background transition releases player hardware and session")
            try pausedMedia(engine, state)
            let saved = defaults.data(forKey: "player.session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
            try check(abs((saved?.elapsed ?? 0) - 6) < 0.15, "background cleanup persists the resumable position")
            engine.setApplicationInBackground(true)
            engine.savePlaybackPosition()
            try check(decoder.stopCount == stops + 1 && state.deactivations == 1,
                      "repeated idle background cleanup is idempotent")
            engine.setApplicationInBackground(false)
            try check(!engine.isPlaying && state.activations.isEmpty && decoder.prepareCount == prepared,
                      "returning to the foreground does not prepare or automatically resume audio")
            engine.resume()
            try finish(state)
            try check(engine.isPlaying && state.decoders.count == 1 && abs(engine.elapsed - 6) < 0.15
                      && decoder.prepareCount == prepared + 1 && decoder.rate == 1.25,
                      "released decoder resumes the same position and speed without rebuilding the queue")
            engine.setApplicationInBackground(true)
            try check(engine.isPlaying && state.sessionIsActive && state.deactivations == 1,
                      "entering the background preserves real playback")
            engine.pause()
            try check(!state.sessionIsActive && state.deactivations == 2 && decoder.stopCount == stops + 2,
                      "pausing already-background playback immediately releases audio resources")
            try pausedMedia(engine, state)
        }

        // A valid route picker/activation must survive a lifecycle transition.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            engine.setApplicationInBackground(true)
            try check(engine.isPreparing && state.deactivations == 0,
                      "background transition does not cancel a valid playback activation")
            try finish(state)
            try check(engine.isPlaying && state.sessionIsActive && state.deactivations == 0,
                      "valid pending playback starts normally after the transition")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            try finish(state)
            engine.pause()
            state.failedDeactivationsRemaining = 1
            engine.setApplicationInBackground(true)
            try check(state.sessionIsActive && state.deactivations == 1 && state.decoders.first?.stopCount == 1,
                      "failed session deactivation still releases player buffers and retains pending cleanup")
            engine.setApplicationInBackground(true)
            try check(!state.sessionIsActive && state.deactivations == 2 && state.decoders.first?.stopCount == 1,
                      "the next lifecycle event retries failed deactivation without stopping buffers twice")
            engine.setApplicationInBackground(true)
            try await Task.sleep(for: .milliseconds(100))
            try check(state.deactivations == 2, "successful cleanup does not create a periodic deactivation retry")
        }

        // Cancellation cannot cancel the system's in-flight activation. Its late
        // success must release the newly activated session without starting audio.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.setApplicationInBackground(true)
            engine.resume()
            engine.pause()
            let beforeLateSuccess = state.deactivations
            try finish(state)
            try check(!engine.isPlaying && !engine.isPreparing && !state.sessionIsActive
                      && state.deactivations > beforeLateSuccess,
                      "late success after background pause is cleaned up without playing")
            try check(state.decoders.first?.playCount == 0,
                      "cancelled activation never starts the decoder")
        }

        // A stale activation must not deactivate the session belonging to a newer
        // request, whichever order the two native callbacks arrive in.
        for staleCompletesFirst in [true, false] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.setApplicationInBackground(true)
            engine.resume()
            engine.pause()
            engine.resume()
            try check(state.activations.count == 2, "race fixture retains old and current activations")
            let beforeCallbacks = state.deactivations
            if staleCompletesFirst {
                try finish(state)
                try check(engine.isPreparing && !engine.isPlaying && state.deactivations == beforeCallbacks,
                          "stale completion cannot release a newer pending playback session")
                try finish(state)
            } else {
                try finish(state, at: 1)
                try check(engine.isPlaying, "newer activation may complete before the stale request")
                try finish(state)
            }
            try check(engine.isPlaying && state.sessionIsActive && state.deactivations == beforeCallbacks,
                      "activation callback order cannot stop newer background playback")
        }

        do {
            let (engine, state) = try fixture()
            engine.resume()
            engine.stop()
            let beforeLateSuccess = state.deactivations
            try finish(state)
            try check(engine.currentURL == nil && !engine.isPlaying && state.systemInfo == nil
                      && !state.sessionIsActive && state.deactivations > beforeLateSuccess,
                      "stop cleans a late activation even while the app remains foreground")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            var outputCompletions = 0
            engine.requestAudioOutput { outputCompletions += 1 }
            engine.setApplicationInBackground(true)
            try check(state.deactivations == 0 && outputCompletions == 0,
                      "background cleanup waits for an open output selector")
            try finish(state)
            try check(outputCompletions == 1 && !engine.isPlaying && !state.sessionIsActive,
                      "paused background output selection completes once then releases its session")

            engine.requestAudioOutput { outputCompletions += 1 }
            engine.resume()
            let beforeCallbacks = state.deactivations
            try finish(state)
            try check(outputCompletions == 2 && engine.isPreparing && state.deactivations == beforeCallbacks,
                      "output completion cannot deactivate a newer pending playback request")
            try finish(state)
            engine.requestAudioOutput { outputCompletions += 1 }
            try finish(state)
            try check(outputCompletions == 3 && engine.isPlaying && state.sessionIsActive
                      && state.deactivations == beforeCallbacks,
                      "output selection during background playback preserves active audio")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            var outputCompletions = 0
            engine.requestAudioOutput { outputCompletions += 1 }
            engine.requestAudioOutput { outputCompletions += 1 }
            engine.setApplicationInBackground(true)
            try finish(state)
            try check(outputCompletions == 1 && state.deactivations == 0 && state.sessionIsActive,
                      "one output completion does not close another outstanding output selector")
            try finish(state)
            try check(outputCompletions == 2 && !state.sessionIsActive && state.deactivations == 1,
                      "the last pending output completion releases idle background audio once")
        }

        // Failed activation/preparation/playback must leave idle background audio
        // released, but a failed track switch must not silence the old song.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.setApplicationInBackground(true)
            engine.resume()
            // A failed native activation may still need cleanup. Model a
            // partially acquired session instead of assuming failure is atomic.
            state.sessionIsActive = true
            let beforeFailure = state.deactivations
            try finish(state, success: false)
            try check(!engine.isPlaying && !engine.isPreparing && !state.sessionIsActive
                      && state.deactivations > beforeFailure,
                      "failed background activation releases any partially acquired audio session")
        }
        for failure in ["prepare", "play", "decode"] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.setApplicationInBackground(true)
            state.decoders.first?.allowsPreparation = failure != "prepare"
            state.decoders.first?.allowsPlayback = failure != "play"
            if failure == "decode" {
                state.rejectDecoderCreation = true
                engine.play(b, in: tracks)
            } else {
                engine.resume()
            }
            try finish(state)
            try check(!engine.isPlaying && !engine.isPreparing && !state.sessionIsActive,
                      "failed background \(failure) releases a successful activation")
            try check(engine.currentURL == a && engine.queue == tracks && state.systemInfo != nil,
                      "failed \(failure) preserves resumable media and system controls")
        }
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            try finish(state)
            engine.setApplicationInBackground(true)
            let beforeFailure = state.deactivations
            engine.play(b, in: tracks)
            try finish(state, success: false)
            try check(engine.isPlaying && engine.currentURL == a && state.sessionIsActive
                      && state.deactivations == beforeFailure,
                      "failed track activation preserves the old song when it is still playing")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            try finish(state)
            engine.seek(to: 6)
            engine.setApplicationInBackground(true)
            engine.setSleepTimer(until: Date().addingTimeInterval(0.05))
            try await waitUntil("background sleep deadline pauses playback", timeout: 1) {
                engine.sleepTimerDeadline == nil && !engine.isPlaying
            }
            try check(!state.sessionIsActive && state.decoders.first?.stopCount == 1,
                      "sleep timer releases background player hardware and session")
            try pausedMedia(engine, state)
            engine.resume()
            try finish(state)
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                                            userInfo: [AVAudioSessionRouteChangeReasonKey:
                                                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            try await waitUntil("headphone disconnection pauses background playback", timeout: 1) { !engine.isPlaying }
            try check(!state.sessionIsActive && state.decoders.first?.stopCount == 2,
                      "headphone disconnection releases background audio resources")
            try pausedMedia(engine, state)
            engine.resume()
            try finish(state)
            try check(engine.isPlaying && abs(engine.elapsed - 6) < 0.15,
                      "background system-play path can resume after timer and route cleanup")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            try finish(state)
            engine.setApplicationInBackground(true)
            func interruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                               AVAudioSessionInterruptionOptionKey: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
            }
            interruption(.began)
            try await waitUntil("interruption pauses background playback", timeout: 1) { !engine.isPlaying }
            try check(!state.sessionIsActive, "background interruption releases idle audio")
            interruption(.ended, shouldResume: true)
            try await waitUntil("eligible interruption requests playback restoration", timeout: 1) { engine.isPreparing }
            try finish(state)
            try check(engine.isPlaying && state.sessionIsActive,
                      "eligible interruption recovery still plays after resource cleanup")
            interruption(.began)
            try await waitUntil("second interruption pauses playback", timeout: 1) { !engine.isPlaying }
            engine.pause()
            interruption(.ended, shouldResume: true)
            try await Task.sleep(for: .milliseconds(100))
            try check(!engine.isPlaying && !engine.isPreparing && state.activations.isEmpty,
                      "explicit pause during an interruption cancels automatic recovery")
        }
        print("BACKGROUND_AUDIO_ENERGY_PASS")
    }

    private enum ProbeError: LocalizedError {
        case failure(String)
        var errorDescription: String? { if case .failure(let message) = self { return message }; return nil }
    }
}

/// Deterministic delegate fixture: real duration/seeking, no audio-device use.
private final class SilentCompletionDecoder: AVAudioPlayer, @unchecked Sendable {
    private var playbackActive = false
    var prepareCount = 0
    var playCount = 0
    var stopCount = 0
    var allowsPreparation = true
    var allowsPlayback = true
    override var isPlaying: Bool { playbackActive }
    override func prepareToPlay() -> Bool { prepareCount += 1; return allowsPreparation }
    override func play() -> Bool { playCount += 1; playbackActive = allowsPlayback; return playbackActive }
    override func pause() { playbackActive = false }
    override func stop() { stopCount += 1; playbackActive = false }
}

@MainActor
private final class PlayerEnergyState {
    var activations: [@MainActor (Bool, String?) -> Void] = []
    var decoders: [SilentCompletionDecoder] = []
    var deactivations = 0
    var failedDeactivationsRemaining = 0
    var sessionIsActive = false
    var rejectDecoderCreation = false
    var systemInfo: [String: Any]?
}
