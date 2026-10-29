import CoreGraphics
import Foundation

@main
struct PhonePlaybackLayoutTests {
    static func main() {
        let sizes = [CGSize(width: 320, height: 460), CGSize(width: 375, height: 600),
                     CGSize(width: 393, height: 720), CGSize(width: 430, height: 800),
                     CGSize(width: 768, height: 920), CGSize(width: 844, height: 320)]
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(value(), message)
        }
        for size in sizes {
            for metadataHeight in [CGFloat(64), 110, 220, 400] {
                for timerHeight in [CGFloat.zero, 48, 90] {
                    let metrics = PhonePlaybackLayout(viewport: size)
                    var natural: [CGFloat] = [44, 0, metadataHeight, 52, 80, 46]
                    if timerHeight > 0 { natural.append(timerHeight) }
                    let layout = metrics.arrange(sectionHeights: natural)
                    check(layout.frames.count == natural.count, "each visible section is placed")
                    check(layout.size.width == size.width && layout.size.height >= size.height,
                          "the page fills the viewport or scrolls beyond it")
                    check(layout.frames[1].width == layout.frames[1].height, "artwork remains square")
                    check(layout.frames[1].width <= metrics.contentWidth, "artwork fits between the side margins")
                    check(abs(layout.frames.last!.maxY + 20 - layout.size.height) < 0.001,
                          "last control/timer ends at the bottom content margin, without a dead blank strip")
                    for (index, frame) in layout.frames.enumerated() {
                        check(frame.minX >= 0 && frame.maxX <= size.width, "all content stays within horizontal bounds")
                        check(frame.minY >= 0 && frame.maxY <= layout.size.height, "all content remains scroll-accessible")
                        if index != 1 {
                            check(frame.height == natural[index], "text and controls never compress to fit")
                        }
                        if index > 0 {
                            check(frame.minY >= layout.frames[index - 1].maxY + 12,
                                  "adjacent sections never overlap")
                        }
                    }
                }
            }
        }
        let small = PhonePlaybackLayout(viewport: CGSize(width: 320, height: 460))
            .arrange(sectionHeights: [44, 0, 400, 90, 80, 46, 90])
        check(small.size.height > 460, "accessibility text can grow and scroll instead of being clipped")
        print("PASS: \(assertions) phone playback layout fill, overflow, natural text and bottom-margin assertions")
    }
}
