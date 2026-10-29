import AVFoundation
import Combine

/// Observes the real system level while the native control owns Crown input.
/// It never changes output volume or takes Crown focus from WatchKit.
@MainActor
final class WatchVolumeFeedback: ObservableObject {
    @Published private(set) var volume: Float = 0
    @Published private(set) var isVisible = false

    private var isActive = false
    private var observation: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var generation = UUID()
    private let dismissDelay: Duration

    init(dismissDelay: Duration = .milliseconds(1400)) {
        self.dismissDelay = dismissDelay
    }

    deinit { hideTask?.cancel() }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        generation = UUID()
        observation = nil
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
        guard active else { return }

        let session = AVAudioSession.sharedInstance()
        volume = min(1, max(0, session.outputVolume))
        let currentGeneration = generation
        observation = session.publisher(for: \.outputVolume, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, self.generation == currentGeneration else { return }
                self.volumeDidChange(value)
            }
    }

    func volumeDidChange(_ value: Float) {
        guard isActive, value.isFinite else { return }
        let level = min(1, max(0, value))
        guard level != volume else { return }
        volume = level
        isVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self, dismissDelay] in
            do { try await Task.sleep(for: dismissDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }
}
