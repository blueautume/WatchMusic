import CoreGraphics
import Foundation

/// Natural heights keep controls readable; the artwork takes the flexible
/// space. Index 1 is the square artwork, following the directory/menu row.
struct PhonePlaybackLayout {
    struct Arrangement {
        let size: CGSize
        let frames: [CGRect]
    }

    let viewport: CGSize
    private var width: CGFloat { max(1, viewport.width) }
    private var horizontalInset: CGFloat { min(28, max(16, width * 0.07)) }
    var contentWidth: CGFloat { max(1, width - horizontalInset * 2) }

    func arrange(sectionHeights: [CGFloat]) -> Arrangement {
        guard sectionHeights.count > 1 else {
            return Arrangement(size: CGSize(width: width, height: max(0, viewport.height)), frames: [])
        }
        let top: CGFloat = 12
        let bottom: CGFloat = 20
        let preferredGaps: [CGFloat] = [12, 24, 20, 24, 24, 16]
        var gaps = (0..<(sectionHeights.count - 1)).map { preferredGaps[min($0, preferredGaps.count - 1)] }
        var heights = sectionHeights.map { $0.isFinite ? max(0, $0) : 0 }
        heights[1] = 0
        let fixedHeight = heights.reduce(0, +) + gaps.reduce(0, +) + top + bottom
        let maximumArtwork = min(400, contentWidth)
        let minimumArtwork = min(144, maximumArtwork)
        heights[1] = min(maximumArtwork, max(minimumArtwork, viewport.height - fixedHeight))

        let naturalHeight = fixedHeight + heights[1]
        let spareHeight = max(0, viewport.height - naturalHeight)
        // Once the artwork reaches the available width, share remaining space
        // between sections instead of leaving a blank area below the controls.
        let weights = gaps.indices.map { index -> CGFloat in index == 0 ? 0 : (index == 1 ? 2 : 1) }
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 0 {
            for index in gaps.indices { gaps[index] += spareHeight * weights[index] / totalWeight }
        }

        var y = top
        let frames = heights.enumerated().map { index, height -> CGRect in
            let side = index == 1 ? heights[1] : contentWidth
            let frame = CGRect(x: (width - side) / 2, y: y, width: side, height: height)
            y += height
            if index < gaps.count { y += gaps[index] }
            return frame
        }
        return Arrangement(size: CGSize(width: width, height: max(naturalHeight, viewport.height)), frames: frames)
    }
}
