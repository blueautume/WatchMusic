import Foundation

@main
struct WatchTransferOrientationTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func sample(_ tracker: inout WatchTransferOrientationTracker,
                       _ x: Double, _ y: Double, _ z: Double = 0) -> WatchTransferOrientation {
        tracker.update(gravityX: x, gravityY: y, gravityZ: z)
    }

    static func turn(_ tracker: inout WatchTransferOrientationTracker, x: Double, y: Double,
                     to expected: WatchTransferOrientation) {
        let original = tracker.orientation
        expect(sample(&tracker, x, y) == original, "First sample must keep the previous direction")
        expect(sample(&tracker, x, y) == original, "Second sample must keep the previous direction")
        expect(sample(&tracker, x, y) == expected, "Three matching samples must change to \(expected)")
        expect(tracker.orientation == expected, "The returned direction must become the tracked direction")
    }

    static func main() {
        expect(WatchTransferOrientation.portrait.rawValue == 0, "Portrait uses zero rotation")
        expect(WatchTransferOrientation.landscapeLeft.rawValue == -90, "Positive x rotates left")
        expect(WatchTransferOrientation.upsideDown.rawValue == 180, "Positive y rotates upside down")
        expect(WatchTransferOrientation.landscapeRight.rawValue == 90, "Negative x rotates right")
        expect(!WatchTransferOrientation.portrait.isLandscape, "Portrait is vertical")
        expect(!WatchTransferOrientation.upsideDown.isLandscape, "Upside down is vertical")
        expect(WatchTransferOrientation.landscapeLeft.isLandscape, "Left uses a landscape layout")
        expect(WatchTransferOrientation.landscapeRight.isLandscape, "Right uses a landscape layout")

        var tracker = WatchTransferOrientationTracker()
        expect(tracker.orientation == .portrait, "The initial display is portrait")
        turn(&tracker, x: 1, y: 0, to: .landscapeLeft)
        turn(&tracker, x: 0, y: 1, to: .upsideDown)
        turn(&tracker, x: -1, y: 0, to: .landscapeRight)
        turn(&tracker, x: 0, y: -1, to: .portrait)

        // Flat on a table has no usable in-plane direction, regardless of side.
        turn(&tracker, x: -1, y: 0, to: .landscapeRight)
        for z in [-1.0, 1.0] {
            for _ in 0..<4 { expect(sample(&tracker, 0, 0, z) == .landscapeRight, "Flat samples retain the previous direction") }
        }

        // A brief tilt near the planar threshold must not accumulate into a turn.
        for x in [0.5501, 0.5499, 0.5501, 0.5499, 0.5501, 0.5499] {
            expect(sample(&tracker, x, 0, sqrt(1 - x * x)) == .landscapeRight,
                   "Crossing the planar threshold without three stable samples must not turn")
        }
        let stableX = 0.5501
        for index in 0..<3 {
            expect(sample(&tracker, stableX, 0, sqrt(1 - stableX * stableX)) == (index == 2 ? .landscapeLeft : .landscapeRight),
                   "Three sufficiently tilted samples may turn")
        }

        // Near-diagonal readings must not flicker between horizontal and vertical.
        tracker.reset()
        for x in [1.26, 1.24, 1.26, 1.24, 1.26, 1.24] {
            expect(sample(&tracker, x, 1) == .portrait, "An unstable dominant-axis threshold retains portrait")
        }
        turn(&tracker, x: 1.26, y: 1, to: .landscapeLeft)
        for _ in 0..<4 { expect(sample(&tracker, 1, 1) == .landscapeLeft, "A diagonal wrist angle retains the last stable direction") }

        // A sample pointing to the current direction interrupts a pending turn.
        tracker.reset()
        expect(sample(&tracker, 1, 0) == .portrait, "A short horizontal movement is ignored")
        expect(sample(&tracker, 1, 0) == .portrait, "Two horizontal samples remain pending")
        expect(sample(&tracker, 0, -1) == .portrait, "The current direction interrupts the turn")
        turn(&tracker, x: 1, y: 0, to: .landscapeLeft)

        // Noise in another valid direction also starts a new three-sample window.
        tracker.reset()
        for x in [1.0, -1, 1, -1, 1, -1, 1, -1] {
            expect(sample(&tracker, x, 0) == .portrait, "Alternating horizontal noise never completes a turn")
        }
        turn(&tracker, x: 1, y: 0, to: .landscapeLeft)

        // Invalid, flat, and ambiguous samples all discard previous candidates.
        let invalidSamples: [(Double, Double, Double)] = [
            (.nan, 0, 0), (0, .nan, 0), (0, 0, .nan),
            (.infinity, 0, 0), (0, -.infinity, 0), (0, 0, .infinity),
            (0, 0, 0), (0, 0, 1), (1, 1, 0)
        ]
        for (x, y, z) in invalidSamples {
            tracker.reset()
            _ = sample(&tracker, 1, 0)
            _ = sample(&tracker, 1, 0)
            expect(sample(&tracker, x, y, z) == .portrait, "Invalid or ambiguous input preserves orientation")
            turn(&tracker, x: 1, y: 0, to: .landscapeLeft)
        }

        // Scaling a usable gravity vector does not change its display direction.
        tracker.reset()
        turn(&tracker, x: -10, y: 0, to: .landscapeRight)
        turn(&tracker, x: 0, y: -0.25, to: .portrait)

        turn(&tracker, x: 0, y: 1, to: .upsideDown)
        _ = sample(&tracker, -1, 0)
        _ = sample(&tracker, -1, 0)
        tracker.reset()
        expect(tracker.orientation == .portrait, "Reset restores portrait")
        turn(&tracker, x: -1, y: 0, to: .landscapeRight)
        for initial in [WatchTransferOrientation.portrait, .landscapeLeft, .upsideDown, .landscapeRight] {
            var resumed = WatchTransferOrientationTracker(orientation: initial)
            expect(sample(&resumed, 0, 0, 1) == initial, "Resuming automatic mode while flat preserves the chosen direction")
        }
        print("PASS: \(assertions) watch transfer orientation assertions")
    }
}
