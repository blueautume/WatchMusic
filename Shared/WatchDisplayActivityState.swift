/// Tracks the lifetime of a display-sleep request, independently of whether the
/// operating system honors it. Inactive/Always On can still be frontmost.
struct WatchDisplayActivityState {
    struct Inputs: Equatable {
        var isCharging: Bool
        var isReceiving: Bool
        var isFrontmost: Bool
        var shouldRequest: Bool { isFrontmost && (isCharging || isReceiving) }
    }
    enum Action: Equatable { case begin, end }
    private(set) var isRequested = false

    mutating func update(_ inputs: Inputs) -> Action? {
        guard inputs.shouldRequest != isRequested else { return nil }
        isRequested = inputs.shouldRequest
        return isRequested ? .begin : .end
    }
}
