import Foundation
import CoreGraphics

/// watchOS owns the physical system clock. Rotated canvases leave its strip
/// unobstructed; native navigation owns the remaining page insets.
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

    /// Only full-canvas content (such as the transfer view) needs this inset.
    /// Native navigation destinations must use their own local geometry instead.
    var fullCanvasTopInset: CGFloat {
        orientation == .portrait ? (min(physicalSize.width, physicalSize.height) < 190 ? 28 : 34) : 0
    }
    var contentSize: CGSize {
        CGSize(width: logicalSize.width, height: max(0, logicalSize.height - fullCanvasTopInset))
    }

    func physicalCanvasCenter(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.minY + systemClockInset + canvasPhysicalSize.height / 2)
    }

    /// This center is relative to the page. A navigation transition's global
    /// translation must never feed back into a destination's local position.
    static func localContentCenter(size: CGSize, topInset: CGFloat) -> CGPoint {
        CGPoint(x: size.width / 2, y: (size.height + topInset) / 2)
    }
}
