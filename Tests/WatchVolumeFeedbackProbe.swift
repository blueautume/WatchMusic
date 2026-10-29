import AVFoundation
import Foundation

/// Runs the production feedback model in a Watch simulator without activating
/// an audio session, playing sound, or changing the system volume. Explicit
/// volume events are fixtures; these assertions do not simulate a physical Crown.
@main
struct WatchVolumeFeedbackProbe {
    @MainActor private static var assertions = 0

    @MainActor
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeError.failure(message) }
        assertions += 1
    }

    @MainActor
    private static func waitUntil(_ message: String, timeout: Duration = .seconds(2),
                                  condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(condition(), message)
    }

    @MainActor
    private static func notifyCurrentSystemVolume(_ session: AVAudioSession) {
        session.willChangeValue(forKey: "outputVolume")
        session.didChangeValue(forKey: "outputVolume")
    }

    @MainActor
    static func main() async {
        do {
            try await run()
            print("PASS: \(assertions) Watch volume feedback observation, debounce and lifecycle assertions (no audio or Crown input)")
        } catch {
            FileHandle.standardError.write(Data("VOLUME_FEEDBACK_PROBE_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let session = AVAudioSession.sharedInstance()
        let baseline = min(1, max(0, session.outputVolume))
        let differentLevel: Float = baseline < 0.5 ? 0.8 : 0.2
        let feedback = WatchVolumeFeedback(dismissDelay: .milliseconds(600))
        defer { feedback.setActive(false) }

        try check(!feedback.isVisible, "new feedback starts hidden")
        feedback.volumeDidChange(differentLevel)
        try check(!feedback.isVisible && feedback.volume == 0, "inactive volume events do not change the model")
        feedback.setActive(true)
        try check(feedback.volume == baseline && !feedback.isVisible,
                  "activation samples the real system level without showing a popup")
        feedback.volumeDidChange(differentLevel)
        try check(feedback.volume == differentLevel && feedback.isVisible,
                  "a changed volume event immediately updates and shows feedback")
        feedback.setActive(true)
        try check(feedback.volume == differentLevel && feedback.isVisible,
                  "repeated activation preserves an in-progress adjustment")

        // Emit a KVO notification for the unchanged live audio-session property.
        // This exercises the actual production subscription and delivery queue
        // without using a private API or writing to the system volume.
        notifyCurrentSystemVolume(session)
        try await waitUntil("active feedback observes the actual AVAudioSession KVO publisher") {
            feedback.volume == baseline
        }
        try check(feedback.isVisible, "a live KVO event uses the same feedback path as a fixture")

        feedback.volumeDidChange(.nan)
        feedback.volumeDidChange(.infinity)
        feedback.volumeDidChange(-.infinity)
        try check(feedback.volume == baseline, "nonfinite events never replace the last valid system level")
        feedback.volumeDidChange(-0.1)
        try check(feedback.volume == 0, "out-of-range low input clamps to mute")
        feedback.volumeDidChange(1.1)
        try check(feedback.volume == 1, "out-of-range high input clamps to full volume")
        feedback.volumeDidChange(0.3)
        try await Task.sleep(for: .milliseconds(350))
        feedback.volumeDidChange(0.6)
        try await Task.sleep(for: .milliseconds(350))
        try check(feedback.isVisible && feedback.volume == 0.6,
                  "a further adjustment cancels the first deadline and remains visible past it")
        try await waitUntil("feedback disappears after the final adjustment settles") { !feedback.isVisible }

        feedback.volumeDidChange(0.6)
        try check(!feedback.isVisible, "a repeated unchanged value does not reopen feedback")
        feedback.volumeDidChange(0.9)
        try await Task.sleep(for: .milliseconds(350))
        feedback.volumeDidChange(0.9)
        feedback.volumeDidChange(.nan)
        try await Task.sleep(for: .milliseconds(350))
        try check(!feedback.isVisible, "duplicate and invalid events do not extend the dismissal deadline")

        feedback.volumeDidChange(0.4)
        try check(feedback.isVisible, "a later adjustment can reopen feedback")
        feedback.setActive(false)
        try check(!feedback.isVisible, "leaving the page immediately hides feedback")
        feedback.volumeDidChange(0.7)
        notifyCurrentSystemVolume(session)
        try await Task.sleep(for: .milliseconds(50))
        try check(feedback.volume == 0.4 && !feedback.isVisible,
                  "inactive feedback rejects fixtures and unsubscribes from live KVO events")

        feedback.setActive(true)
        try check(feedback.volume == baseline && !feedback.isVisible,
                  "returning to the page resamples system volume without a stale popup")
        feedback.volumeDidChange(differentLevel)
        notifyCurrentSystemVolume(session)
        feedback.setActive(false)
        feedback.setActive(true)
        feedback.volumeDidChange(differentLevel)
        try await Task.sleep(for: .milliseconds(50))
        try check(feedback.volume == differentLevel && feedback.isVisible,
                  "queued KVO delivery from an old page cannot overwrite a new adjustment")
        try await Task.sleep(for: .milliseconds(300))
        feedback.setActive(false)
        feedback.setActive(true)
        feedback.volumeDidChange(differentLevel)
        try await Task.sleep(for: .milliseconds(350))
        try check(feedback.isVisible && feedback.volume == differentLevel,
                  "a canceled deadline from a previous page cannot hide the new page feedback")
        try await waitUntil("the new page feedback still dismisses on its own deadline") { !feedback.isVisible }
        try check(session.outputVolume == baseline, "the probe never writes to the system volume")
    }

    private enum ProbeError: LocalizedError {
        case failure(String)
        var errorDescription: String? {
            if case let .failure(message) = self { return message }
            return nil
        }
    }
}
