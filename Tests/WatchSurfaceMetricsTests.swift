import Foundation
import CoreGraphics

@main
struct WatchSurfaceMetricsTests {
    static func main() {
        var checks = 0
        for size in [CGSize(width: 162, height: 197), CGSize(width: 176, height: 215),
                     CGSize(width: 184, height: 224), CGSize(width: 198, height: 242),
                     CGSize(width: 205, height: 251), CGSize(width: 211, height: 257)] {
            let bounds = CGRect(origin: CGPoint(x: 8, y: 12), size: size)
            for orientation in [WatchTransferOrientation.portrait, .landscapeLeft, .landscapeRight, .upsideDown] {
                let metrics = WatchSurfaceMetrics(physicalSize: size, orientation: orientation)
                let canvas = CGSize(width: size.width, height: size.height - metrics.systemClockInset)
                let expected = orientation.isLandscape ? CGSize(width: canvas.height, height: canvas.width) : canvas
                precondition(metrics.logicalSize == expected, "Each direction must retain the area below the native clock")
                precondition(metrics.contentSize.width == expected.width, "Moving battery into a title never shrinks the canvas width")
                precondition(metrics.contentSize.height + metrics.fullCanvasTopInset == expected.height,
                             "Full-canvas content reserves only the native clock, without an extra battery row")
                precondition(metrics.fullCanvasTopInset <= 34 && metrics.contentSize.height >= 130,
                             "Small watches retain usable space after removing the separate status row")
                let canvasCenter = metrics.physicalCanvasCenter(in: bounds)
                precondition(canvasCenter.x == bounds.midX && canvasCenter.y == bounds.midY + metrics.systemClockInset / 2,
                             "Only the outer scene canvas compensates for the fixed physical clock")
                precondition(orientation == .portrait || metrics.systemClockInset >= 30,
                             "Rotated app content must not collide with the fixed system clock")
                let localCenter = WatchSurfaceMetrics.localContentCenter(size: metrics.logicalSize, topInset: metrics.fullCanvasTopInset)
                for translation in [-expected.width, -expected.width / 2, 0, expected.width / 2, expected.width] {
                    let pageFrame = CGRect(x: translation, y: 0, width: expected.width, height: expected.height)
                    let centerDuringPush = WatchSurfaceMetrics.localContentCenter(size: pageFrame.size, topInset: metrics.fullCanvasTopInset)
                    precondition(centerDuringPush == localCenter,
                                 "A page's local layout never cancels a native navigation translation")
                    let renderedCenter = CGPoint(x: pageFrame.minX + centerDuringPush.x, y: centerDuringPush.y)
                    precondition(abs(renderedCenter.x - localCenter.x - translation) < 0.001,
                                 "Incoming and outgoing pages keep the system's full push offset")
                    checks += 2
                }
                checks += 6
            }
        }
        print("PASS: \(checks) Watch local-page and native-clock layout assertions")
    }
}
