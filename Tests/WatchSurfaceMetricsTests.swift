import Foundation
import CoreGraphics

@main
struct WatchSurfaceMetricsTests {
    static func main() {
        var checks = 0
        for size in [CGSize(width: 162, height: 197), CGSize(width: 205, height: 251), CGSize(width: 211, height: 257)] {
            let bounds = CGRect(origin: CGPoint(x: 8, y: 12), size: size)
            for orientation in [WatchTransferOrientation.portrait, .landscapeLeft, .landscapeRight, .upsideDown] {
                let metrics = WatchSurfaceMetrics(physicalSize: size, orientation: orientation)
                let canvas = CGSize(width: size.width, height: size.height - metrics.systemClockInset)
                let expected = orientation.isLandscape ? CGSize(width: canvas.height, height: canvas.width) : canvas
                precondition(metrics.logicalSize == expected, "Each direction must retain the area below the native clock")
                precondition(metrics.contentSize.width == expected.width, "The status row never shrinks content width")
                precondition(metrics.contentSize.height + metrics.statusHeight == expected.height, "The status row is reserved exactly once")
                precondition(metrics.statusInset >= 14 && metrics.contentSize.height >= 130, "Small watches retain curved-edge margins and usable content")
                let center = metrics.physicalContentCenter(in: bounds)
                let canvasCenter = metrics.physicalCanvasCenter(in: bounds)
                let angle = Double(orientation.rawValue) * .pi / 180
                let x = center.x - canvasCenter.x
                let y = center.y - canvasCenter.y
                let logicalX = x * cos(angle) + y * sin(angle)
                let logicalY = -x * sin(angle) + y * cos(angle)
                precondition(abs(logicalX) < 0.001 && abs(logicalY - metrics.statusHeight / 2) < 0.001,
                             "Content remains below the status row after an inverse rotation")
                precondition(orientation == .portrait || metrics.systemClockInset >= 30,
                             "Rotated app content must not collide with the fixed system clock")
                checks += 6
            }
        }
        print("PASS: \(checks) Watch status-row layout assertions")
    }
}
