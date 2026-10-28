import Foundation
import CoreGraphics

@main
struct WatchSurfaceMetricsTests {
    private static var checks = 0
    private static var failures: [String] = []
    private static let epsilon: CGFloat = 0.000_001

    static func main() {
        let sizes = [CGSize(width: 162, height: 197), CGSize(width: 176, height: 215),
                     CGSize(width: 184, height: 224), CGSize(width: 198, height: 242),
                     CGSize(width: 205, height: 251), CGSize(width: 211, height: 257)]
        let orientations: [WatchTransferOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .upsideDown]
        for size in sizes {
            for orientation in orientations {
                let context = "\(Int(size.width))×\(Int(size.height)), \(orientation)"
                let metrics = WatchSurfaceMetrics(physicalSize: size, orientation: orientation)
                verifyFullCanvas(metrics, context: context)
                verifyClockMapping(metrics, context: context)
                for usage in [(action: false, title: true, name: "root"),
                              (action: true, title: true, name: "list"),
                              (action: true, title: false, name: "playback")] {
                    verifyPageInsets(metrics, hasAction: usage.action, hasTitle: usage.title,
                                     context: context + ", " + usage.name)
                }
            }
        }
        guard failures.isEmpty else {
            failures.forEach { FileHandle.standardError.write(Data(("FAIL: " + $0 + "\n").utf8)) }
            fatalError("\(failures.count) of \(checks) full-canvas/clock/navigation assertions failed")
        }
        print("PASS: \(checks) full-canvas, clock-clearance and local-navigation assertions")
    }

    private static func verifyFullCanvas(_ metrics: WatchSurfaceMetrics, context: String) {
        let size = metrics.physicalSize
        let logical = metrics.logicalSize
        check(close(logical.width * logical.height, size.width * size.height),
              context + ": rotating never removes a physical clock strip or reduces canvas area")
        check(close(min(logical.width, logical.height), min(size.width, size.height)) &&
              close(max(logical.width, logical.height), max(size.width, size.height)),
              context + ": rotation retains both physical side lengths")
        let mappedCanvas = boundingRect(corners(CGRect(origin: .zero, size: logical)).map {
            physicalPoint($0, metrics: metrics)
        })
        check(close(mappedCanvas, CGRect(origin: .zero, size: size)),
              context + ": the rotated canvas reaches every physical display edge")
        for origin in [CGPoint.zero, CGPoint(x: 8, y: 12), CGPoint(x: -30.5, y: 21.25)] {
            let bounds = CGRect(origin: origin, size: size)
            let center = metrics.physicalCanvasCenter(in: bounds)
            check(close(center.x, bounds.midX) && close(center.y, bounds.midY),
                  context + ": the outer canvas stays centered without orientation-dependent compensation")
        }
        let localCenter = metrics.physicalCanvasCenter(in: CGRect(origin: .zero, size: size))
        for translation in [-logical.width, -logical.width / 2, logical.width / 2, logical.width] {
            let pageBounds = CGRect(x: translation, y: 0, width: size.width, height: size.height)
            let renderedCenter = metrics.physicalCanvasCenter(in: pageBounds)
            check(close(renderedCenter.x - localCenter.x, translation) && close(renderedCenter.y, localCenter.y),
                  context + ": an external navigation translation is preserved rather than cancelled by centering")
        }
    }

    private static func verifyClockMapping(_ metrics: WatchSurfaceMetrics, context: String) {
        let physical = metrics.physicalClockFrame
        let logical = metrics.clockFrame
        let bounds = CGRect(origin: .zero, size: metrics.logicalSize)
        check(close(physical.maxX, metrics.physicalSize.width) && close(physical.minY, 0),
              context + ": the system clock remains at the physical upper-right corner")
        check(bounds.contains(logical), context + ": inverse-mapped clock stays inside the full logical canvas")
        check(close(logical.width * logical.height, physical.width * physical.height),
              context + ": clock avoidance transforms only the small corner rectangle")
        let physicalAgain = boundingRect(corners(logical).map { physicalPoint($0, metrics: metrics) })
        check(close(physicalAgain, physical),
              context + ": each clock corner maps back to the fixed physical clock under actual rotation")
        switch metrics.orientation {
        case .portrait:
            check(close(logical.maxX, bounds.maxX) && close(logical.minY, bounds.minY),
                  context + ": portrait clock belongs to the logical upper-right corner")
        case .landscapeRight:
            check(close(logical.minX, bounds.minX) && close(logical.minY, bounds.minY),
                  context + ": clockwise clock belongs to the logical upper-left corner")
        case .landscapeLeft:
            check(close(logical.maxX, bounds.maxX) && close(logical.maxY, bounds.maxY),
                  context + ": counterclockwise clock belongs to the logical lower-right corner")
        case .upsideDown:
            check(close(logical.minX, bounds.minX) && close(logical.maxY, bounds.maxY),
                  context + ": upside-down clock belongs to the logical lower-left corner")
        }
    }

    private static func verifyPageInsets(_ metrics: WatchSurfaceMetrics, hasAction: Bool, hasTitle: Bool,
                                         context: String) {
        let size = metrics.logicalSize
        let insets = metrics.pageInsets(hasAction: hasAction, hasTitle: hasTitle)
        let bodyHeight = size.height - insets.headerHeight
        let amounts = [insets.headerHeight, insets.metadataLeading, insets.metadataTrailing,
                       insets.bottomControlLeading, insets.bottomControlTrailing, insets.bottomControlBottom,
                       insets.scrollTop, insets.scrollBottom, insets.rowLeading, insets.rowTrailing]
        check(amounts.allSatisfy { $0.isFinite && $0 >= 0 }, context + ": every content inset is finite and nonnegative")
        check(bodyHeight > 100, context + ": small watches retain a useful local body below the header")
        check(size.width - insets.metadataLeading - insets.metadataTrailing >= 72,
              context + ": clock and Back leave useful metadata width even on the smallest watch")
        check(size.width - insets.rowLeading - insets.rowTrailing >= 100,
              context + ": curved-edge row padding does not collapse a small watch list")
        check(size.width - insets.bottomControlLeading - insets.bottomControlTrailing >= 132,
              context + ": bottom insets retain at least three standard 44-point control widths")
        check(insets.scrollTop + insets.scrollBottom < bodyHeight / 2,
              context + ": scroll padding does not replace most of the viewport with an empty band")
        check(close(insets.bodyClockFrame.offsetBy(dx: 0, dy: insets.headerHeight), metrics.clockFrame),
              context + ": the clock obstacle moves into body-local coordinates without resizing the page")

        // Metadata may occupy a 64-point-high first row. Test its allowed region,
        // not one particular artwork/font layout that could hide an overlap.
        let metadata = CGRect(x: insets.metadataLeading, y: 0,
                              width: size.width - insets.metadataLeading - insets.metadataTrailing,
                              height: min(64, bodyHeight))
        if hasAction && !hasTitle {
            check(!overlaps(metadata, insets.bodyClockFrame), context + ": playback metadata cannot draw under the clock")
            let backInBody = insets.backFrame.offsetBy(dx: 0, dy: -insets.headerHeight)
            check(!overlaps(metadata, backInBody), context + ": playback metadata cannot overlap the Back touch target")
        }
        if hasAction {
            check(CGRect(origin: .zero, size: size).contains(insets.backFrame),
                  context + ": the complete Back target remains on screen")
            check(insets.backFrame.width >= 44 && insets.backFrame.height >= 44,
                  context + ": reclaiming canvas space does not shrink the navigation touch target")
            check(!overlaps(insets.backFrame, metrics.clockFrame), context + ": Back and the physical clock remain separate")
        } else {
            check(insets.backFrame.isNull, context + ": a root page does not reserve an invisible Back target")
        }

        // A normal 44-point transport row must fit above/beside the clock. This
        // checks a functional target rather than copying playback view profiles.
        let controls = CGRect(x: insets.bottomControlLeading,
                              y: bodyHeight - insets.bottomControlBottom - 44,
                              width: size.width - insets.bottomControlLeading - insets.bottomControlTrailing,
                              height: 44)
        check(controls.minY >= 0, context + ": the bottom control row fits inside the body")
        check(!overlaps(controls, insets.bodyClockFrame), context + ": bottom controls avoid the clock in every orientation")


    }

    /// An independent forward rotation verifies the production inverse rectangle
    /// mapping; it deliberately does not repeat the four inverse switch formulas.
    private static func physicalPoint(_ point: CGPoint, metrics: WatchSurfaceMetrics) -> CGPoint {
        let angle = Double(metrics.orientation.rawValue) * .pi / 180
        let x = Double(point.x - metrics.logicalSize.width / 2)
        let y = Double(point.y - metrics.logicalSize.height / 2)
        return CGPoint(x: Double(metrics.physicalSize.width / 2) + x * cos(angle) - y * sin(angle),
                       y: Double(metrics.physicalSize.height / 2) + x * sin(angle) + y * cos(angle))
    }

    private static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    private static func boundingRect(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private static func overlaps(_ left: CGRect, _ right: CGRect) -> Bool {
        guard !left.isNull, !right.isNull else { return false }
        let intersection = left.intersection(right)
        return !intersection.isNull && intersection.width > epsilon && intersection.height > epsilon
    }

    private static func close(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < epsilon }
    private static func close(_ left: CGRect, _ right: CGRect) -> Bool {
        close(left.minX, right.minX) && close(left.minY, right.minY) &&
        close(left.width, right.width) && close(left.height, right.height)
    }
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
}
