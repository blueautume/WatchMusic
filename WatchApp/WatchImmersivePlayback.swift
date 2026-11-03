import CoreGraphics
import Foundation

/// A single deadline, invalidated on interaction or suspension. A late task
/// cannot put a newly touched or dismissed page back into immersive mode.
struct WatchImmersivePlayback {
    struct IdleRequest: Equatable {
        let generation: UInt64
        let deadline: TimeInterval
    }

    static let idleInterval: TimeInterval = 5
    private(set) var isImmersive = false
    private(set) var idleRequest: IdleRequest?
    private var isEligible = false
    private var generation: UInt64 = 0

    mutating func setEligible(_ eligible: Bool, at now: TimeInterval) {
        guard eligible != isEligible else { return }
        isEligible = eligible
        schedule(at: now)
    }

    mutating func interact(at now: TimeInterval) {
        isImmersive = false
        schedule(at: now)
    }

    mutating func suspend() {
        isEligible = false
        isImmersive = false
        generation &+= 1
        idleRequest = nil
    }

    @discardableResult
    mutating func enter(for request: IdleRequest, at now: TimeInterval) -> Bool {
        guard isEligible, idleRequest == request, now >= request.deadline else { return false }
        isImmersive = true
        idleRequest = nil
        return true
    }

    private mutating func schedule(at now: TimeInterval) {
        generation &+= 1
        idleRequest = isEligible && !isImmersive
            ? IdleRequest(generation: generation, deadline: now + Self.idleInterval) : nil
    }
}

/// Both the cover and its caption use the same safe column. The system clock
/// can occupy a lower corner after rotation, not only the usual top corner.
struct WatchImmersiveLayout {
    let artworkFrame: CGRect
    let titleFrame: CGRect

    init(size: CGSize, clockFrame: CGRect = .null, titleHeight: CGFloat = 34,
         centeredVertically: Bool = false) {
        let inset: CGFloat = 12
        let gap: CGFloat = 8
        let top: CGFloat = centeredVertically ? 12 : 2
        var bottom: CGFloat = 12
        if !clockFrame.isNull, clockFrame.width > size.width * 0.4,
           clockFrame.minY > size.height / 2, clockFrame.minY < size.height {
            bottom = max(bottom, size.height - clockFrame.minY + 8)
        }
        let band = CGRect(x: 0, y: top, width: size.width, height: max(0, size.height - top - bottom))
        var leading = inset
        var trailing = inset
        if !clockFrame.isNull, clockFrame.intersects(band) {
            if clockFrame.midX < size.width / 2 { leading = max(leading, clockFrame.maxX + 6) }
            else { trailing = max(trailing, size.width - clockFrame.minX + 6) }
        }
        let width = max(0, size.width - leading - trailing)
        let side = max(0, min(width, band.height - titleHeight - gap))
        let centerX = leading + width / 2
        let groupHeight = side + gap + titleHeight
        let groupY = centeredVertically ? band.midY - groupHeight / 2 : top
        artworkFrame = CGRect(x: centerX - side / 2, y: groupY, width: side, height: side)
        titleFrame = CGRect(x: leading, y: artworkFrame.maxY + gap, width: width, height: titleHeight)
    }
}
