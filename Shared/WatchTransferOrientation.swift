import Foundation

enum WatchTransferOrientation: Int {
    case portrait = 0
    case landscapeLeft = -90
    case upsideDown = 180
    case landscapeRight = 90

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

/// Uses normalized display coordinates; crown-side correction belongs to the
/// motion caller. Ambiguous or interrupted samples never complete a turn.
struct WatchTransferOrientationTracker {
    private(set) var orientation: WatchTransferOrientation = .portrait
    private var pendingOrientation: WatchTransferOrientation?
    private var consecutiveSamples = 0

    init(orientation: WatchTransferOrientation = .portrait) { self.orientation = orientation }

    mutating func update(gravityX: Double, gravityY: Double, gravityZ: Double) -> WatchTransferOrientation {
        guard let candidate = candidate(gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ),
              candidate != orientation else {
            clearPending()
            return orientation
        }
        if candidate == pendingOrientation { consecutiveSamples += 1 }
        else { pendingOrientation = candidate; consecutiveSamples = 1 }
        if consecutiveSamples >= 3 {
            orientation = candidate
            clearPending()
        }
        return orientation
    }

    mutating func reset() {
        orientation = .portrait
        clearPending()
    }

    private mutating func clearPending() {
        pendingOrientation = nil
        consecutiveSamples = 0
    }

    private func candidate(gravityX: Double, gravityY: Double, gravityZ: Double) -> WatchTransferOrientation? {
        guard gravityX.isFinite, gravityY.isFinite, gravityZ.isFinite else { return nil }
        let magnitude = hypot(hypot(gravityX, gravityY), gravityZ)
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        let x = gravityX / magnitude
        let y = gravityY / magnitude
        guard hypot(x, y) >= 0.55 else { return nil }
        let horizontal = abs(x)
        let vertical = abs(y)
        guard max(horizontal, vertical) >= min(horizontal, vertical) * 1.25 else { return nil }
        if horizontal > vertical { return x > 0 ? .landscapeLeft : .landscapeRight }
        return y > 0 ? .upsideDown : .portrait
    }
}
