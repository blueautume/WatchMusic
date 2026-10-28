import Foundation
import CoreGraphics

/// The app's battery row turns with its pages. The system clock stays in its
/// physical corner on watchOS, so turned canvases leave that strip unobstructed.
struct WatchSurfaceMetrics {
    let physicalSize: CGSize
    let orientation: WatchTransferOrientation

    var systemClockInset: CGFloat {
        orientation == .portrait ? 0 : (min(physicalSize.width, physicalSize.height) < 190 ? 30 : 38)
    }

    var canvasPhysicalSize: CGSize {
        CGSize(width: physicalSize.width, height: max(0, physicalSize.height - systemClockInset))
    }

    var logicalSize: CGSize {
        orientation.isLandscape
            ? CGSize(width: canvasPhysicalSize.height, height: canvasPhysicalSize.width)
            : canvasPhysicalSize
    }

    var statusHeight: CGFloat {
        orientation == .portrait ? (min(physicalSize.width, physicalSize.height) < 190 ? 30 : 52) : 24
    }
    var statusInset: CGFloat { min(physicalSize.width, physicalSize.height) < 190 ? 16 : 20 }
    var contentSize: CGSize {
        CGSize(width: logicalSize.width, height: max(0, logicalSize.height - statusHeight))
    }

    func physicalCanvasCenter(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.minY + systemClockInset + canvasPhysicalSize.height / 2)
    }

    func physicalContentCenter(in bounds: CGRect) -> CGPoint {
        let angle = Double(orientation.rawValue) * .pi / 180
        let center = physicalCanvasCenter(in: bounds)
        return CGPoint(x: center.x - sin(angle) * statusHeight / 2,
                       y: center.y + cos(angle) * statusHeight / 2)
    }
}
