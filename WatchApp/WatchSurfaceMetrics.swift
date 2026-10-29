import Foundation
import CoreGraphics

/// Rotate the full physical display. The native clock occupies a corner, not
/// a strip that should be removed from every list and page.
struct WatchSurfaceMetrics {
    let physicalSize: CGSize
    let orientation: WatchTransferOrientation

    var logicalSize: CGSize {
        orientation.isLandscape
            ? CGSize(width: physicalSize.height, height: physicalSize.width) : physicalSize
    }

    var physicalClockFrame: CGRect {
        let width: CGFloat = physicalSize.width < 190 ? 90 : 98
        let height: CGFloat = physicalSize.width < 190 ? 32 : 36
        return CGRect(x: max(0, physicalSize.width - width), y: 0,
                      width: min(width, physicalSize.width), height: height)
    }

    var clockFrame: CGRect {
        let clock = physicalClockFrame
        switch orientation {
        case .portrait: return clock
        case .landscapeRight:
            return CGRect(x: clock.minY, y: physicalSize.width - clock.maxX,
                          width: clock.height, height: clock.width)
        case .landscapeLeft:
            return CGRect(x: physicalSize.height - clock.maxY, y: clock.minX,
                          width: clock.height, height: clock.width)
        case .upsideDown:
            return CGRect(x: physicalSize.width - clock.maxX, y: physicalSize.height - clock.maxY,
                          width: clock.width, height: clock.height)
        }
    }

    func physicalCanvasCenter(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func pageInsets(hasAction: Bool, hasTitle: Bool) -> WatchPageInsets {
        let header: CGFloat
        if hasAction && !hasTitle {
            // Landscape playback shares its first row with a compact Back
            // control instead of spending a whole row on navigation.
            header = orientation == .portrait ? 46 : 0
        } else if orientation == .portrait {
            header = clockFrame.maxY + (hasAction ? 20 : 28)
        } else { header = hasAction ? 46 : 32 }

        let buttonX: CGFloat = orientation == .landscapeRight
            ? logicalSize.width - 56 : 12
        let button = hasAction ? CGRect(x: buttonX, y: 2, width: 44, height: 44) : .null
        return WatchPageInsets(size: logicalSize, headerHeight: header,
                               clockFrame: clockFrame, backFrame: button)
    }
}

/// Insets constrain text and hit targets only. Backgrounds and scrolling rows
/// can still paint through the curved display edges and behind the small header.
struct WatchPageInsets {
    let headerHeight: CGFloat
    let bodyClockFrame: CGRect
    let backFrame: CGRect
    let metadataLeading: CGFloat
    let metadataTrailing: CGFloat
    let bottomControlLeading: CGFloat
    let bottomControlTrailing: CGFloat
    let bottomControlBottom: CGFloat
    let scrollTop: CGFloat
    let scrollBottom: CGFloat
    let rowLeading: CGFloat
    let rowTrailing: CGFloat

    init(size: CGSize, headerHeight: CGFloat, clockFrame: CGRect, backFrame: CGRect) {
        self.headerHeight = headerHeight
        self.backFrame = backFrame
        bodyClockFrame = clockFrame.offsetBy(dx: 0, dy: -headerHeight)
        let height = max(0, size.height - headerHeight)
        let metadataBand = CGRect(x: 0, y: 0, width: size.width, height: min(70, height))
        let bottomBand = CGRect(x: 0, y: max(0, height - 72), width: size.width, height: min(72, height))
        func sides(avoiding regions: [CGRect], in band: CGRect) -> (CGFloat, CGFloat) {
            var leading: CGFloat = 12
            var trailing: CGFloat = 12
            for region in regions where !region.isNull && region.intersects(band) {
                if region.midX < size.width / 2 { leading = max(leading, region.maxX + 6) }
                else { trailing = max(trailing, size.width - region.minX + 6) }
            }
            return (leading, trailing)
        }
        let bodyBack = headerHeight == 0 ? backFrame : .null
        (metadataLeading, metadataTrailing) = sides(avoiding: [bodyClockFrame, bodyBack], in: metadataBand)
        let isBottomClock = bodyClockFrame.width > size.width * 0.4 && bodyClockFrame.intersects(bottomBand)
        (bottomControlLeading, bottomControlTrailing) = sides(
            avoiding: isBottomClock ? [] : [bodyClockFrame], in: bottomBand)
        bottomControlBottom = isBottomClock ? bodyClockFrame.height + 8 : 12
        scrollTop = 2
        scrollBottom = isBottomClock ? bodyClockFrame.height + 12 : 14
        let listBand = CGRect(x: 0, y: 0, width: size.width, height: height)
        (rowLeading, rowTrailing) = sides(avoiding: isBottomClock ? [] : [bodyClockFrame], in: listBand)
    }
}
