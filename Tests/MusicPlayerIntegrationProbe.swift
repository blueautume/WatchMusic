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
        }, activateAudioSession: { activations.append($0) },
           audioOutputPorts: { [AudioOutputPort(kind: .bluetooth, name: "Probe Headphones")] },
           publishNowPlayingInfo: { completionInfo = $0 })
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
                                       activateAudioSession: { outputCallbacks.append($0) },
                                       audioOutputPorts: { [AudioOutputPort(kind: .bluetooth, name: "Probe Headphones")] })
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

        try await runAudioOutputIntentTests(tracks: [a, b, c], snapshot: snapshot)
        try await runAudioOutputCancellationTests(tracks: [a, b, c], snapshot: snapshot)
        try await runNativeSessionPipelineTests(tracks: [a, b, c], snapshot: snapshot)
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
    private static func runAudioOutputIntentTests(tracks: [URL], snapshot: Session) async throws {
        let a = tracks[0], b = tracks[1], c = tracks[2]
        let headphones = [AudioOutputPort(kind: .bluetooth, name: "Probe AirPods Pro")]
        func fixture(ports: [AudioOutputPort] = []) throws -> (MusicPlayer, OutputIntentState) {
            UserDefaults.standard.set(try JSONEncoder().encode(snapshot), forKey: "player.session")
            let state = OutputIntentState()
            state.ports = ports
            let engine = MusicPlayer(makeAudioPlayer: { url in
                let decoder = try SilentCompletionDecoder(contentsOf: url)
                state.decoders.append(decoder)
                return decoder
            }, activateAudioSession: { state.activations.append($0) }, audioOutputPorts: { state.ports },
               deactivateAudioSession: { state.deactivations += 1 }, publishNowPlayingInfo: { _ in })
            return (engine, state)
        }
        func finish(_ state: OutputIntentState, at index: Int = 0, success: Bool = true) throws {
            try check(state.activations.indices.contains(index), "output intent has exactly the expected native activation")
            state.activations.remove(at: index)(success, success ? nil : "Native route selection canceled")
        }
        func route(_ state: OutputIntentState, ports: [AudioOutputPort],
                   reason: AVAudioSession.RouteChangeReason = .newDeviceAvailable) async throws {
            state.ports = ports
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                                            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
            // Notification observers hand off to MainActor. This also gives a
            // forbidden delayed action a chance to run before negative checks.
            try await Task.sleep(for: .milliseconds(50))
        }
        func interruption(_ type: AVAudioSession.InterruptionType) async throws {
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
            try await Task.sleep(for: .milliseconds(50))
        }

        // Actual route snapshots update the UI independently of playback. Merely
        // opening the output selector never creates a deferred play intention.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            try check(!engine.audioOutput.isConnected && !engine.isSelectingAudioOutput,
                      "no external output starts disconnected and idle")
            engine.requestAudioOutput()
            try check(engine.isSelectingAudioOutput && !engine.isPreparing && state.activations.count == 1,
                      "manual output selection publishes its own pending state")
            try await route(state, ports: headphones)
            try check(engine.audioOutput.isConnected && engine.audioOutput.deviceName == "Probe AirPods Pro",
                      "route notification publishes the connected device name")
            try finish(state)
            engine.setApplicationActive(false)
            engine.setApplicationActive(true)
            try check(!engine.isPlaying && !engine.isPreparing && !engine.isSelectingAudioOutput
                      && state.decoders.allSatisfy { $0.playCount == 0 },
                      "manual output selection and return to app never start a paused song")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.requestAudioOutput()
            NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            try await waitUntil("audio reset clears a manual output selector even if its old callback never arrives", timeout: 1) {
                !engine.isSelectingAudioOutput
            }
            engine.errorMessage = nil
            engine.requestAudioOutput()
            try finish(state, success: false)
            try check(engine.isSelectingAudioOutput && engine.errorMessage == nil,
                      "a pre-reset output callback cannot finish or overwrite a new selection")
            try finish(state)
            try check(!engine.isSelectingAudioOutput && !engine.isPlaying,
                      "post-reset manual selection finishes without creating a play intent")
        }

        #if os(watchOS)
        // A route can become available before the original native callback. The
        // system picker may emit interruption/disconnection events while doing
        // so; those transitions must not invalidate this initial play request.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.play(b, in: tracks)
            try check(engine.isPreparing && engine.isSelectingAudioOutput && state.activations.count == 1,
                      "an explicit play without output owns one native selection")
            engine.setApplicationActive(false)
            try await interruption(.began)
            try await route(state, ports: [], reason: .oldDeviceUnavailable)
            try check(engine.isPreparing && state.activations.count == 1,
                      "initial picker interruption and empty-route transition preserve the play request")
            try await route(state, ports: headphones)
            try finish(state)
            try check(engine.isPreparing && !engine.isPlaying && engine.isSelectingAudioOutput,
                      "authorized route selection waits for the app to return active")
            // No legacy .ended interruption is required: the successful native
            // activation is authoritative for this original explicit play action.
            engine.setApplicationActive(true)
            try check(engine.isPlaying && engine.currentURL == b && !engine.isSelectingAudioOutput
                      && state.activations.isEmpty && state.decoders.last?.playCount == 1,
                      "returning from output connection automatically starts the originally requested song once")
            try await route(state, ports: headphones)
            engine.setApplicationActive(true)
            try check(state.activations.isEmpty && state.decoders.last?.playCount == 1,
                      "duplicate route and active events do not replay or reactivate the song")
        }

        // The native completion can arrive first, including before currentRoute
        // catches up. Authorization is sufficient once the app is active; the
        // external-device presentation snapshot is not a playback prerequisite.
        for activeArrivesFirst in [true, false] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.seek(to: 6)
            engine.resume()
            engine.setApplicationActive(false)
            try finish(state)
            try check(engine.isPreparing && !engine.isPlaying && state.decoders.first?.playCount == 0,
                      "native authorization during picker inactivity retains the request until app return")
            if activeArrivesFirst {
                engine.setApplicationActive(true)
                try check(engine.isPlaying && !engine.isPreparing && state.ports.isEmpty,
                          "active-before-route starts the authorized request without waiting for a presentation snapshot")
                try await route(state, ports: headphones)
            } else {
                try await route(state, ports: headphones)
                try check(!engine.isPlaying, "route-before-active still waits for picker return")
                engine.setApplicationActive(true)
            }
            try check(engine.isPlaying && engine.currentURL == a && abs(engine.elapsed - 6) < 0.15
                      && state.decoders.first?.playCount == 1 && state.activations.isEmpty,
                      "callback, route and lifecycle ordering preserves one resume at the original position")
        }

        // This models the production adapter's empty snapshot, including a raw
        // virtual route omitted from the external-device UI. No route event is
        // delivered after native authorization. The old route gate left both
        // Preparing and Selecting true and disabled every subsequent attempt.
        for action in ["play", "resume"] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            if action == "play" { engine.play(b, in: tracks) }
            else { engine.resume() }
            try finish(state)
            try check(state.ports.isEmpty && engine.isPlaying && !engine.isPreparing && !engine.isSelectingAudioOutput,
                      "native success with an empty or filtered-virtual snapshot finishes \(action) without a route notification")
            try check(state.decoders.last?.playCount == 1, "authorized empty-snapshot playback is attempted once")
            engine.requestAudioOutput()
            try check(state.activations.count == 1 && engine.isSelectingAudioOutput,
                      "empty-snapshot native success leaves the manual output action able to reach the native adapter again")
            try finish(state)
            try check(!engine.isSelectingAudioOutput && engine.isPlaying,
                      "the subsequent manual action completes independently of the old playback request")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            state.decoders.first?.allowsPlayback = false
            engine.resume()
            try finish(state)
            try check(state.ports.isEmpty && !engine.isPlaying && !engine.isPreparing && !engine.isSelectingAudioOutput
                      && engine.errorMessage != nil,
                      "decoder failure after native success with no displayed route reports an error instead of locking controls")
            engine.requestAudioOutput()
            try check(state.activations.count == 1, "reported playback failure does not suppress a subsequent native output action")
            try finish(state)
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            engine.setApplicationActive(false)
            try await route(state, ports: headphones)
            try finish(state)
            try await interruption(.began)
            engine.setApplicationActive(true)
            try check(!engine.isPlaying && !engine.isPreparing && !engine.isSelectingAudioOutput,
                      "a new genuine interruption after authorization cancels deferred playback before app return")
            try await interruption(.ended)
            try check(!engine.isPlaying && state.activations.isEmpty,
                      "ending that interruption cannot revive an unstarted canceled request")
        }

        // Cancellation/failure is final. Reconnecting headphones or returning
        // active later must not resurrect the canceled play request.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.play(b, in: tracks)
            engine.setApplicationActive(false)
            try finish(state, success: false)
            try await route(state, ports: headphones)
            engine.setApplicationActive(true)
            try check(!engine.isPlaying && !engine.isPreparing && !engine.isSelectingAudioOutput
                      && state.activations.isEmpty && state.decoders.allSatisfy { $0.playCount == 0 },
                      "native cancellation cannot play after a later connection or app return")
            try check(state.deactivations > 0, "native cancellation releases its idle activated resources")
        }

        for cancellation in ["pause", "stop", "remove", "invalid-track", "next-without-track", "media-reset"] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            if cancellation == "next-without-track" { engine.stop() }
            engine.play(b, in: tracks)
            switch cancellation {
            case "pause": engine.pause()
            case "stop": engine.stop()
            case "remove": engine.removeFromQueue(b)
            case "invalid-track": engine.play(b.appendingPathComponent("missing.mp3"), in: [])
            case "media-reset":
                NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
                try await waitUntil("media reset cancels pending play", timeout: 1) { !engine.isPreparing }
            default: engine.next()
            }
            try await route(state, ports: headphones)
            try finish(state)
            engine.setApplicationActive(true)
            try check(!engine.isPlaying && !engine.isPreparing && state.decoders.allSatisfy { $0.playCount == 0 },
                      "\(cancellation) invalidates the pending play before late native success")
        }

        for staleCompletesFirst in [true, false] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.play(b, in: tracks)
            engine.play(c, in: tracks)
            try await route(state, ports: headphones)
            if staleCompletesFirst {
                try finish(state)
                try check(!engine.isPlaying && engine.isPreparing,
                          "old track authorization cannot start the replacement request")
                try finish(state)
            } else {
                try finish(state, at: 1)
                try finish(state)
            }
            try check(engine.isPlaying && engine.currentURL == c && state.decoders.last?.playCount == 1
                      && state.activations.isEmpty,
                      "switching tracks preserves only the latest intent regardless of native callback order")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            engine.previous()
            try check(engine.isPreparing && engine.elapsed < 0.15 && state.activations.count == 1,
                      "previous while resuming the same song resets its position without canceling the route request")
            try await route(state, ports: headphones)
            try finish(state)
            try check(engine.isPlaying && engine.currentURL == a && engine.elapsed < 0.15,
                      "the original pending resume starts from zero after previous")
        }

        for navigation in ["next", "previous-track", "previous-reset-current"] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            if navigation != "previous-reset-current" { engine.seek(to: 0) }
            engine.play(b, in: tracks)
            if navigation == "next" { engine.next() }
            else { engine.previous() }
            try check(state.activations.count == 2, "track navigation replaces the pending route request")
            try await route(state, ports: headphones)
            try finish(state)
            try check(!engine.isPlaying && engine.isPreparing,
                      "track navigation ignores the old route callback")
            try finish(state)
            let target = navigation == "next" ? b : (navigation == "previous-track" ? c : a)
            try check(engine.isPlaying && engine.currentURL == target && engine.elapsed < 0.15,
                      "\(navigation) starts only its replacement track at zero")
        }

        // Once an external output was observed, losing it is a real disconnect,
        // even if the original selection callback has not arrived yet.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.play(b, in: tracks)
            try await route(state, ports: headphones)
            try await route(state, ports: [], reason: .oldDeviceUnavailable)
            try finish(state)
            try await route(state, ports: headphones)
            try check(!engine.isPlaying && !engine.isPreparing && !engine.isSelectingAudioOutput,
                      "a real disconnect after connection cancels the pending play permanently")
            engine.resume()
            try finish(state)
            try await route(state, ports: [], reason: .oldDeviceUnavailable)
            try await route(state, ports: headphones)
            try check(!engine.isPlaying && state.activations.isEmpty,
                      "disconnecting active playback never auto-resumes on reconnection")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.play(b, in: tracks)
            // The device connected and disconnected before MainActor handled
            // either notification. Both handlers see the current empty route,
            // but the disconnection event still carries its previous device.
            state.ports = []
            engine.audioOutputRouteDidChange(reason: .newDeviceAvailable, previousPorts: [])
            engine.audioOutputRouteDidChange(reason: .oldDeviceUnavailable, previousPorts: headphones)
            try finish(state)
            try await route(state, ports: headphones)
            engine.setApplicationActive(true)
            try check(!engine.isPlaying && !engine.isPreparing && !engine.isSelectingAudioOutput
                      && state.decoders.allSatisfy { $0.playCount == 0 },
                      "previous-route evidence cancels a fast connect/disconnect before delayed native success")
        }

        // Newer watches may authorize built-in speaker playback. It remains a
        // disconnected external-device display and must work for system Play
        // commands while the app is already in the background.
        for active in [true, false] {
            let (engine, state) = try fixture(ports: [AudioOutputPort(kind: .builtIn, name: "Watch Speaker")])
            defer { engine.stop() }
            engine.setApplicationActive(active)
            engine.setApplicationInBackground(!active)
            engine.resume()
            try finish(state)
            try check(engine.isPlaying && !engine.audioOutput.isConnected && !engine.isSelectingAudioOutput,
                      "authorized built-in speaker playback works for foreground and background system play")
        }
        do {
            let (engine, state) = try fixture(ports: [AudioOutputPort(kind: .builtIn, name: "Watch Speaker")])
            defer { engine.stop() }
            engine.resume()
            engine.setApplicationActive(false)
            engine.setApplicationInBackground(true)
            try finish(state)
            try check(engine.isPlaying && !engine.isPreparing,
                      "a valid built-in output request may finish after moving from foreground to background")
        }
        #endif
        print("AUDIO_OUTPUT_INTENT_PASS")
    }

    @MainActor
    private static func runAudioOutputCancellationTests(tracks: [URL], snapshot: Session) async throws {
        let a = tracks[0], b = tracks[1]
        let headphones = [AudioOutputPort(kind: .bluetooth, name: "Probe AirPods")]
        let cocoaCancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        let urlCancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let wrappedCancellation = NSError(domain: "RouteSelectionWrapper", code: 1,
                                          userInfo: [NSUnderlyingErrorKey: cocoaCancellation])
        func fixture(fresh: Bool = false) throws -> (MusicPlayer, OutputCancellationState) {
            if fresh { UserDefaults.standard.removeObject(forKey: "player.session") }
            else { UserDefaults.standard.set(try JSONEncoder().encode(snapshot), forKey: "player.session") }
            let state = OutputCancellationState()
            let engine = MusicPlayer(makeAudioPlayer: { url in
                if state.rejectDecoderCreation {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                                  userInfo: [NSLocalizedDescriptionKey: "Corrupt audio fixture"])
                }
                let decoder = try SilentCompletionDecoder(contentsOf: url)
                state.decoders.append(decoder)
                return decoder
            }, activateAudioSessionWithError: {
                if let error = state.configurationError { throw error }
                state.activations.append($0)
            },
               audioOutputPorts: { state.ports },
               deactivateAudioSession: { state.deactivations += 1 }, publishNowPlayingInfo: { _ in })
            return (engine, state)
        }
        func begin(_ engine: MusicPlayer, action: String) {
            if action == "play" { engine.play(b, in: tracks) }
            else if action == "resume" { engine.resume() }
            else { engine.requestAudioOutput() }
        }
        func finish(_ state: OutputCancellationState, activated: Bool = false, error: NSError? = nil) throws {
            try check(state.activations.count == 1, "selection completion belongs to one pending native adapter call")
            state.activations.removeFirst()(activated, error)
        }

        var cancellations: [NSError?] = [cocoaCancellation, urlCancellation, wrappedCancellation]
        #if os(watchOS)
        cancellations.insert(nil, at: 0)
        cancellations.append(NSError(domain: NSOSStatusErrorDomain, code: -123456,
                                     userInfo: [NSLocalizedDescriptionKey: "Unspecified native route result"]))
        cancellations.append(NSError(domain: NSOSStatusErrorDomain, code: Int(AVAudioSession.ErrorCode.cannotStartPlaying.rawValue)))
        #endif
        for action in ["play", "resume", "manual"] {
            for cancellation in cancellations {
                let (engine, state) = try fixture()
                defer { engine.stop() }
                engine.seek(to: 6)
                begin(engine, action: action)
                engine.setApplicationActive(false)
                try finish(state, error: cancellation)
                try check(!engine.isPreparing && !engine.isSelectingAudioOutput && !engine.isPlaying
                          && engine.errorMessage == nil,
                          "\(action) unselected/canceled native result quietly restores the Play state")
                try check(engine.currentURL == a && engine.queue == tracks && abs(engine.elapsed - 6) < 0.15,
                          "canceling \(action) preserves the existing paused song, queue and position")
                try check(state.deactivations > 0, "canceled idle selection releases its session even in the foreground")
                state.ports = headphones
                engine.audioOutputRouteDidChange(reason: .newDeviceAvailable, previousPorts: [])
                engine.setApplicationActive(true)
                try check(!engine.isPlaying && state.activations.isEmpty,
                          "connecting later cannot resurrect a canceled \(action) request")
                begin(engine, action: action)
                try finish(state, activated: true)
                try check(!engine.isPreparing && !engine.isSelectingAudioOutput && engine.isPlaying == (action != "manual"),
                          "a deliberate retry after canceled \(action) can reach and complete native activation")
            }
        }

        // Fresh selection must remain resumable after backing out of the picker.
        // Loading it paused performs decoding only, never prepare/activation/play.
        for cancellation in cancellations {
            let (engine, state) = try fixture(fresh: true)
            defer { engine.stop() }
            try check(engine.currentURL == nil && state.decoders.isEmpty, "fresh cancellation fixture has no saved media")
            engine.play(b, in: tracks)
            try finish(state, error: cancellation)
            try check(engine.currentURL == b && engine.queue == tracks && engine.elapsed < 0.15
                      && !engine.isPreparing && !engine.isSelectingAudioOutput && !engine.isPlaying
                      && engine.errorMessage == nil,
                      "fresh picker cancellation retains the requested song as a usable paused selection")
            try check(state.decoders.count == 1 && state.decoders[0].prepareCount == 0 && state.decoders[0].playCount == 0,
                      "retaining a canceled first selection does not prepare audio hardware or start playback")
            state.ports = headphones
            engine.audioOutputRouteDidChange(reason: .newDeviceAvailable, previousPorts: [])
            engine.setApplicationActive(true)
            try check(!engine.isPlaying && state.activations.isEmpty, "fresh canceled media cannot auto-play on connection")
            engine.togglePlayback()
            try finish(state, activated: true)
            try check(engine.isPlaying && engine.currentURL == b && state.decoders[0].playCount == 1,
                      "the restored Play button can retry a canceled first song")
        }

        let failures = [AVAudioSession.ErrorCode.badParam, .cannotStartPlaying, .insufficientPriority,
                        .missingEntitlement, .mediaServicesFailed, .resourceNotAvailable].map {
            NSError(domain: NSOSStatusErrorDomain, code: Int($0.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Actual audio-session failure: \($0.rawValue)"])
        } + [NSError(domain: NSOSStatusErrorDomain, code: Int(AVAudioSession.ErrorCode.mediaServicesFailed.rawValue),
                     userInfo: [NSLocalizedDescriptionKey: "Media services failed", NSUnderlyingErrorKey: cocoaCancellation]),
             NSError(domain: "NativeActivationFailure", code: 2, userInfo: [NSLocalizedDescriptionKey: "Activation service failed"])]
        for action in ["play", "resume", "manual"] {
            for failure in failures {
                let (engine, state) = try fixture()
                defer { engine.stop() }
                state.ports = headphones
                engine.audioOutputRouteDidChange(reason: .newDeviceAvailable, previousPorts: [])
                begin(engine, action: action)
                try finish(state, error: failure)
                try check(engine.errorMessage == failure.localizedDescription && !engine.isPlaying
                          && !engine.isPreparing && !engine.isSelectingAudioOutput,
                          "\(action) preserves native failures when an output route was already present")
                try check(state.deactivations > 0, "failed idle \(action) selection releases any partially acquired session")
            }
        }

        for action in ["play", "resume", "manual"] {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            let configurationError = NSError(domain: NSOSStatusErrorDomain, code: Int(AVAudioSession.ErrorCode.badParam.rawValue),
                                             userInfo: [NSLocalizedDescriptionKey: "Invalid session configuration"])
            state.configurationError = configurationError
            begin(engine, action: action)
            try check(engine.errorMessage == configurationError.localizedDescription && state.activations.isEmpty
                      && !engine.isPreparing && !engine.isSelectingAudioOutput && !engine.isPlaying,
                      "\(action) configuration throws remain visible even in an entirely unrouted session")
        }

        // An output seen during selection prevents the unrouted-return policy,
        // even if it disconnects again before a manual native callback arrives.
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            let failure = NSError(domain: NSOSStatusErrorDomain, code: -123456,
                                  userInfo: [NSLocalizedDescriptionKey: "Native route disappeared"])
            engine.requestAudioOutput()
            state.ports = headphones
            engine.audioOutputRouteDidChange(reason: .newDeviceAvailable, previousPorts: [])
            state.ports = []
            engine.audioOutputRouteDidChange(reason: .oldDeviceUnavailable, previousPorts: headphones)
            try finish(state, error: failure)
            try check(engine.errorMessage == failure.localizedDescription && !engine.isSelectingAudioOutput,
                      "a native error after an observed connection is not mistaken for backing out without selecting")
        }

        #if os(watchOS)
        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            try finish(state, activated: true)
            try check(engine.isPlaying, "old-route notification fixture starts the prior song")
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                                            userInfo: [AVAudioSessionRouteChangeReasonKey:
                                                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            try check(!engine.isPlaying && !engine.isPreparing,
                      "a main-queue old-route notification finishes before a later request can begin")
            engine.play(b, in: tracks)
            try await Task.sleep(for: .milliseconds(50))
            try check(engine.isPreparing && engine.isSelectingAudioOutput && state.activations.count == 1,
                      "an old notification cannot asynchronously cancel a newer unrouted selection")
            try finish(state, error: NSError(domain: NSOSStatusErrorDomain, code: -123456))
            try check(engine.errorMessage == nil && !engine.isPreparing && !engine.isSelectingAudioOutput,
                      "the newer entirely unrouted selection still returns quietly after the old event")
        }
        #endif

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.requestAudioOutput()
            let failure = NSError(domain: NSOSStatusErrorDomain, code: Int(AVAudioSession.ErrorCode.badParam.rawValue),
                                  userInfo: [NSLocalizedDescriptionKey: "New playback configuration failed"])
            state.configurationError = failure
            engine.resume()
            try check(engine.errorMessage == failure.localizedDescription, "a newer playback reports its configuration failure")
            try finish(state, error: cocoaCancellation)
            try check(engine.errorMessage == failure.localizedDescription && !engine.isSelectingAudioOutput,
                      "an older manual selection cancellation cannot erase a newer playback error")
        }

        do {
            let (engine, state) = try fixture()
            defer { engine.stop() }
            engine.resume()
            try finish(state, activated: true)
            let plays = state.decoders.first?.playCount
            let deactivations = state.deactivations
            engine.requestAudioOutput()
            try finish(state, error: cocoaCancellation)
            try check(engine.isPlaying && engine.errorMessage == nil && state.decoders.first?.playCount == plays
                      && state.deactivations == deactivations,
                      "canceling manual output selection neither stops nor restarts an existing playing song")
        }

        do {
            let (engine, state) = try fixture(fresh: true)
            defer { engine.stop() }
            engine.play(b, in: tracks)
            state.rejectDecoderCreation = true
            try finish(state, error: cocoaCancellation)
            try check(engine.errorMessage?.contains("Corrupt audio fixture") == true
                      && !engine.isPreparing && !engine.isSelectingAudioOutput && !engine.isPlaying,
                      "a genuine decoder error while retaining canceled media still reports the corrupt file")
        }
        print("AUDIO_OUTPUT_CANCELLATION_PASS")
    }

    /// Runs the production asynchronous executor path. The older synchronous
    /// activation/deactivation hooks are intentionally not supplied here.
    @MainActor
    private static func runNativeSessionPipelineTests(tracks: [URL], snapshot: Session) async throws {
        let a = tracks[0], b = tracks[1]
        let cancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        let headphones = [AudioOutputPort(kind: .bluetooth, name: "Pipeline AirPods Pro")]
        func fixture(fresh: Bool = false) throws -> (MusicPlayer, NativePipelineState, NativePipelineBackend) {
            if fresh { UserDefaults.standard.removeObject(forKey: "player.session") }
            else { UserDefaults.standard.set(try JSONEncoder().encode(snapshot), forKey: "player.session") }
            let state = NativePipelineState()
            let backend = NativePipelineBackend()
            let executor = AudioSessionExecutor(configure: { try backend.configure($0) },
                                                activate: { backend.activate($0) },
                                                deactivate: { try backend.deactivate() })
            let engine = MusicPlayer(makeAudioPlayer: { url in
                let decoder = try SilentCompletionDecoder(contentsOf: url)
                state.decoders.append(decoder)
                return decoder
            }, audioSessionExecutor: executor, audioOutputPorts: { state.ports }, publishNowPlayingInfo: { _ in })
            return (engine, state, backend)
        }

        // The manual idle request must enter native activation again even if
        // an earlier empty-route selection already activated the session.
        do {
            let (engine, _, backend) = try fixture()
            defer { engine.stop() }
            engine.seek(to: 6)
            engine.requestAudioOutput()
            try await waitUntil("native pipeline receives a manual no-output selection") { backend.snapshot.activations == 1 }
            try check(backend.snapshot.deactivationsAtActivation == [1],
                      "manual idle selection resets the native session before its first activation")
            try check(backend.completeNext(activated: false, error: cancellation), "manual pipeline cancellation has a native completion")
            try await waitUntil("manual native cancellation clears selection and releases its idle session") {
                !engine.isSelectingAudioOutput && !backend.snapshot.sessionIsActive
            }
            try check(engine.errorMessage == nil && engine.currentURL == a && abs(engine.elapsed - 6) < 0.15,
                      "manual native cancellation quietly retains the paused song and position")
            let beforeRetry = backend.snapshot.deactivations
            engine.requestAudioOutput()
            try await waitUntil("reopening idle no-output selection invokes native activation again") { backend.snapshot.activations == 2 }
            try check((backend.snapshot.deactivationsAtActivation.last ?? 0) > beforeRetry,
                      "each deliberate idle no-output reselection performs a fresh native reset")
            try check(backend.snapshot.configurations == 1, "reselecting output does not repeat unchanged native configuration")
            try check(backend.completeNext(activated: true), "manual native retry completes")
            try await waitUntil("manual native retry releases the selection UI") { !engine.isSelectingAudioOutput }
            try check(!engine.isPlaying && engine.errorMessage == nil, "manual native success never starts a paused song")
            try check(backend.snapshot.mainThreadOperations.isEmpty, "manual native session mutations are off the main thread")
        }

        // Setup failure must retain its distinct error path; otherwise the
        // watch's empty-route native-false policy would swallow this failure.
        do {
            let (engine, _, backend) = try fixture()
            defer { engine.stop() }
            let failure = NSError(domain: "PipelineConfigurationFailure", code: 41,
                                  userInfo: [NSLocalizedDescriptionKey: "Native pipeline configuration failed"])
            backend.failNextConfiguration(with: failure)
            engine.requestAudioOutput()
            try await waitUntil("native setup failure is reported with no output route") {
                !engine.isSelectingAudioOutput && engine.errorMessage != nil
            }
            try check(engine.errorMessage == failure.localizedDescription && backend.snapshot.activations == 0,
                      "empty-route configuration failure remains visible without calling native activation")
            try check(!engine.isPreparing && !engine.isPlaying, "setup failure restores the idle player controls")
            try check(backend.snapshot.mainThreadOperations.isEmpty, "failed native setup is also executed off main")
        }

        for fresh in [false, true] {
            let (engine, state, backend) = try fixture(fresh: fresh)
            defer { engine.stop() }
            if fresh { engine.play(b, in: tracks) }
            else { engine.seek(to: 6); engine.resume() }
            try await waitUntil("production executor starts the pending play selection") { backend.snapshot.activations == 1 }
            try check(backend.completeNext(activated: false, error: cancellation), "play selection receives its native canceled result")
            try await waitUntil("production cancellation restores a usable paused selection") {
                !engine.isPreparing && !engine.isSelectingAudioOutput && engine.currentURL != nil
            }
            try check(engine.errorMessage == nil && !engine.isPlaying && engine.queue == tracks,
                      "production cancellation returns to the player without a restoration error")
            try check(engine.currentURL == (fresh ? b : a) && abs(engine.elapsed - (fresh ? 0 : 6)) < 0.15,
                      "production cancellation preserves the fresh song or existing playback position")
            try check(state.decoders.allSatisfy { $0.playCount == 0 && $0.prepareCount == 0 },
                      "retaining a canceled selection never prepares or plays audio")
            engine.togglePlayback()
            try await waitUntil("restored Play control can request the native pipeline again") { backend.snapshot.activations == 2 }
            try check(backend.completeNext(activated: true), "deliberate native playback retry succeeds")
            try await waitUntil("native retry starts the selected silent decoder once") { engine.isPlaying && !engine.isPreparing }
            try check(state.decoders.reduce(0) { $0 + $1.playCount } == 1,
                      "one deliberate retry produces one playback start after cancellation")
            try check(backend.snapshot.mainThreadOperations.isEmpty, "play retry uses only off-main native session mutations")
        }

        // A real queued cleanup is held on the worker while a new Play intent
        // arrives on MainActor, then released before the replacement activates.
        do {
            let (engine, state, backend) = try fixture()
            defer { engine.stop() }
            state.ports = headphones
            engine.resume()
            try await waitUntil("cleanup-race fixture starts its first native activation") { backend.snapshot.activations == 1 }
            try check(backend.completeNext(activated: true), "cleanup-race fixture authorizes its first play")
            try await waitUntil("cleanup-race fixture is playing") { engine.isPlaying }
            backend.blockNextDeactivation()
            let watchdog = DispatchWorkItem { backend.releaseDeactivationBlock() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
            defer { watchdog.cancel(); backend.releaseDeactivationBlock() }
            engine.setApplicationInBackground(true)
            engine.pause()
            try await waitUntil("idle native cleanup is held on the worker") { backend.snapshot.deactivationBlocked }
            engine.resume()
            try check(engine.isPreparing && !engine.isPlaying,
                      "a new Play intent remains responsive while older native cleanup is blocked")
            backend.releaseDeactivationBlock()
            try await waitUntil("replacement activation advances after old cleanup acknowledgement") { backend.snapshot.activations == 2 }
            try check(backend.completeNext(activated: true), "replacement activation receives its own native result")
            try await waitUntil("replacement playback is active after asynchronous cleanup") { engine.isPlaying && !engine.isPreparing }
            try check(backend.snapshot.sessionIsActive && state.decoders.first?.playCount == 2,
                      "queued old cleanup cannot stop or duplicate the replacement playback")
            try check(backend.snapshot.mainThreadOperations.isEmpty, "cleanup and replacement activation never mutate the native session on main")
        }
        print("NATIVE_AUDIO_SESSION_PIPELINE_PASS")
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
               audioOutputPorts: { [AudioOutputPort(kind: .bluetooth, name: "Probe Headphones")] },
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

@MainActor
private final class OutputIntentState {
    var ports: [AudioOutputPort] = []
    var activations: [@MainActor (Bool, String?) -> Void] = []
    var decoders: [SilentCompletionDecoder] = []
    var deactivations = 0
}

@MainActor
private final class OutputCancellationState {
    var ports: [AudioOutputPort] = []
    var activations: [@MainActor (Bool, NSError?) -> Void] = []
    var decoders: [SilentCompletionDecoder] = []
    var deactivations = 0
    var rejectDecoderCreation = false
    var configurationError: NSError?
}

@MainActor
private final class NativePipelineState {
    var ports: [AudioOutputPort] = []
    var decoders: [SilentCompletionDecoder] = []
}

/// Thread-safe inert native adapter for the production executor integration.
/// It deliberately completes activations from a non-main queue.
private final class NativePipelineBackend: @unchecked Sendable {
    typealias Completion = @Sendable (Bool, NSError?) -> Void

    struct Snapshot {
        let configurations: Int
        let activations: Int
        let deactivations: Int
        let deactivationsAtActivation: [Int]
        let sessionIsActive: Bool
        let deactivationBlocked: Bool
        let mainThreadOperations: [String]
    }

    private let lock = NSLock()
    private var configurations = 0
    private var activations = 0
    private var deactivations = 0
    private var deactivationsAtActivation: [Int] = []
    private var sessionIsActive = false
    private var mainThreadOperations: [String] = []
    private var completions: [Completion] = []
    private var configurationError: NSError?
    private var shouldBlockDeactivation = false
    private var deactivationBlocked = false
    private let deactivationGate = DispatchSemaphore(value: 0)

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(configurations: configurations, activations: activations, deactivations: deactivations,
                        deactivationsAtActivation: deactivationsAtActivation, sessionIsActive: sessionIsActive,
                        deactivationBlocked: deactivationBlocked, mainThreadOperations: mainThreadOperations)
    }

    func configure(_ configuration: AudioSessionExecutor.Configuration) throws {
        lock.lock()
        configurations += 1
        if Thread.isMainThread { mainThreadOperations.append("configure") }
        let error = configurationError
        configurationError = nil
        lock.unlock()
        if let error { throw error }
    }

    func activate(_ completion: @escaping Completion) {
        lock.lock()
        defer { lock.unlock() }
        if Thread.isMainThread { mainThreadOperations.append("activate") }
        activations += 1
        deactivationsAtActivation.append(deactivations)
        completions.append(completion)
        // Failure can still leave a partially acquired native session. Cleanup
        // must not assume that a false callback means no resources were used.
        sessionIsActive = true
    }

    func deactivate() throws {
        lock.lock()
        if Thread.isMainThread { mainThreadOperations.append("deactivate") }
        let block = shouldBlockDeactivation
        shouldBlockDeactivation = false
        if block { deactivationBlocked = true }
        lock.unlock()
        if block { deactivationGate.wait() }
        lock.lock()
        deactivationBlocked = false
        deactivations += 1
        sessionIsActive = false
        lock.unlock()
    }

    func failNextConfiguration(with error: NSError) {
        lock.lock()
        configurationError = error
        lock.unlock()
    }

    func blockNextDeactivation() {
        lock.lock()
        shouldBlockDeactivation = true
        lock.unlock()
    }

    func releaseDeactivationBlock() { deactivationGate.signal() }

    func completeNext(activated: Bool, error: NSError? = nil) -> Bool {
        lock.lock()
        guard !completions.isEmpty else { lock.unlock(); return false }
        let completion = completions.removeFirst()
        lock.unlock()
        DispatchQueue.global().async { completion(activated, error) }
        return true
    }
}
