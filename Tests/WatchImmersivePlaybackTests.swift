import CoreGraphics
import Foundation

/// Deterministic deadlines exercise late/canceled task delivery without sleeps.
/// Geometry checks use the same body-local system clock as the actual page.
@main
struct WatchImmersivePlaybackTests {
    private static var checks = 0
    private static var failures: [String] = []
    private static let epsilon: CGFloat = 0.000_001
    private static let frontmost = WatchImmersivePlayback.Availability(
        isBackground: false, hasTrack: true, isObstructed: false, isPreparing: false
    )

    static func main() {
        verifyExactDeadlineAndOneShotEntry()
        verifyRepeatedInteraction()
        verifyEligibilityRearm()
        verifySuspensionAndStaleDelivery()
        verifyFrontmostDeadlineAcrossWake()
        verifyUnavailablePageRestartsIdleWindow()
        verifyPreparationWhileImmersive()
        verifyLayouts()
        guard failures.isEmpty else {
            failures.forEach { FileHandle.standardError.write(Data(("FAIL: " + $0 + "\n").utf8)) }
            exit(1)
        }
        print("PASS: \(checks) Watch immersive deadline, lifecycle and clock-safe layout assertions")
    }

    private static func verifyExactDeadlineAndOneShotEntry() {
        var state = WatchImmersivePlayback()
        check(WatchImmersivePlayback.idleInterval == 5, "entry waits five seconds")
        check(!state.isImmersive && state.idleRequest == nil, "a new page starts with controls and no task")
        state.setEligible(false, at: 10)
        state.interact(at: 11)
        check(state.idleRequest == nil && !state.isImmersive, "an unavailable page does not arm on touch")
        state.setEligible(true, at: 100)
        let pending = request(state, "initial eligibility")
        check(pending.deadline == 105, "eligibility arms the complete five-second interval")
        check(!state.enter(for: pending, at: 104.999), "4.999 seconds is too early")
        check(!state.isImmersive && state.idleRequest == pending, "early delivery preserves controls and pending deadline")
        state.setEligible(true, at: 104.5)
        check(state.idleRequest == pending, "an unchanged eligible observation does not postpone entry")
        check(state.enter(for: pending, at: 105), "exactly five seconds enters immersive playback")
        check(state.isImmersive && state.idleRequest == nil, "entry consumes its one-shot deadline")
        check(!state.enter(for: pending, at: 106), "duplicate task completion cannot enter twice")
        state.setEligible(true, at: 200)
        check(state.isImmersive && state.idleRequest == nil, "remaining immersive never schedules recurring entry")
        state.interact(at: 201)
        let afterTouch = request(state, "touch exits immersive playback")
        check(!state.isImmersive && afterTouch.deadline == 206, "touch restores controls and starts a fresh five seconds")
        check(!state.enter(for: pending, at: 206), "an old completion cannot undo touch exit")
        check(state.idleRequest == afterTouch && !state.isImmersive, "rejected stale completion preserves the new task")
        check(!state.enter(for: afterTouch, at: 205.999), "the interval after exit is also five complete seconds")
        check(state.enter(for: afterTouch, at: 206), "the new deadline can reenter after a touch exit")
    }

    private static func verifyRepeatedInteraction() {
        var state = WatchImmersivePlayback()
        state.setEligible(true, at: 10)
        var oldRequests = [request(state, "before repeated interaction")]
        for index in 1...20 {
            let now = 10 + Double(index) * 0.17
            state.interact(at: now)
            let pending = request(state, "interaction \(index)")
            check(pending.deadline == now + 5, "interaction \(index) moves the deadline to five seconds after that touch")
            check(!oldRequests.contains(pending), "interaction \(index) invalidates every previous task identity")
            check(!state.isImmersive, "interaction \(index) retains the normal controls")
            for old in oldRequests {
                check(!state.enter(for: old, at: pending.deadline), "interaction \(index) rejects a late older deadline")
            }
            check(state.idleRequest == pending, "late deliveries after interaction \(index) do not replace the current deadline")
            oldRequests.append(pending)
        }
        let latest = request(state, "last interaction")
        check(!state.enter(for: latest, at: latest.deadline - 0.001), "the last touch is not bypassed by earlier idle time")
        check(state.enter(for: latest, at: latest.deadline), "only the final interaction's deadline can enter")
        check(state.isImmersive && state.idleRequest == nil, "repeated interactions still end in one one-shot entry")
    }

    private static func verifyEligibilityRearm() {
        var state = WatchImmersivePlayback()
        state.setEligible(true, at: 50)
        let beforePause = request(state, "before eligibility suspension")
        state.setEligible(false, at: 54)
        check(state.idleRequest == nil && !state.isImmersive, "losing eligibility cancels pending entry")
        check(!state.enter(for: beforePause, at: 55), "an unavailable page rejects its canceled deadline")
        state.interact(at: 56)
        check(state.idleRequest == nil, "touch while unavailable does not start a replacement task")
        state.setEligible(true, at: 60)
        let resumed = request(state, "eligibility resumed")
        check(resumed.deadline == 65 && resumed != beforePause, "resuming eligibility starts a new full interval")
        state.setEligible(true, at: 64)
        check(state.idleRequest == resumed, "repeated active observations keep the resumed deadline")
        check(!state.enter(for: beforePause, at: 65), "a canceled task is still rejected after the page becomes eligible again")
        check(!state.enter(for: resumed, at: 64.999), "time spent suspended does not count toward the resumed interval")
        check(state.enter(for: resumed, at: 65), "eligibility resume enters only on its new deadline")
    }

    private static func verifySuspensionAndStaleDelivery() {
        var state = WatchImmersivePlayback()
        state.setEligible(true, at: 100)
        let beforeLeaving = request(state, "before leaving page")
        state.suspend()
        check(!state.isImmersive && state.idleRequest == nil, "leaving the page clears mode and pending work")
        check(!state.enter(for: beforeLeaving, at: 200), "late work cannot enter a page that has left the screen")
        state.setEligible(true, at: 100)
        let afterReturn = request(state, "after returning page")
        check(afterReturn.deadline == beforeLeaving.deadline && afterReturn != beforeLeaving,
              "a fresh page visit uses a distinct task even if its deadline happens to match")
        check(!state.enter(for: beforeLeaving, at: 105), "matching old and new deadline times do not revive an old task")
        check(state.enter(for: afterReturn, at: 105), "the returning page's own task can enter")
        state.suspend()
        check(!state.isImmersive && state.idleRequest == nil, "suspending an immersive page immediately restores normal mode")
        state.suspend()
        check(!state.isImmersive && state.idleRequest == nil, "repeated suspension remains idle without a replacement task")
        state.interact(at: 106)
        check(state.idleRequest == nil, "a late physical interaction cannot rearm a suspended page")
        check(!state.enter(for: afterReturn, at: 1000), "completed work stays invalid after suspension and touch")
    }

    private static func verifyFrontmostDeadlineAcrossWake() {
        for (wakeTime, entersOnWake) in [(3.0, false), (6.0, true)] {
            var state = WatchImmersivePlayback()
            state.updateAvailability(frontmost, at: 0)
            let pending = request(state, "before the display dims")
            check(pending.deadline == 5, "a ready frontmost page schedules entry at five seconds")

            // Inactive or Always On presentation leaves the page frontmost.
            // The view's task can defer delivery until the display wakes.
            state.updateAvailability(frontmost, at: 2)
            check(state.idleRequest == pending && !state.isImmersive,
                  "dimming preserves the pending deadline while the page stays frontmost")
            state.updateAvailability(frontmost, at: wakeTime)
            check(state.idleRequest == pending, "waking does not start a second five-second interval")
            check(state.enter(for: pending, at: wakeTime) == entersOnWake,
                  "waking at \(wakeTime) seconds honors the original deadline")
            if !entersOnWake {
                check(state.idleRequest == pending, "waking early keeps the original task valid")
                check(state.enter(for: pending, at: 5), "an early wake waits only until the original fifth second")
            }

            state.updateAvailability(frontmost, at: 7)
            check(state.isImmersive && state.idleRequest == nil,
                  "dimming an already immersed frontmost page preserves its layout without arming a timer")
        }
    }

    private static func verifyUnavailablePageRestartsIdleWindow() {
        let unavailable: [(String, WatchImmersivePlayback.Availability)] = [
            ("entering the background", .init(isBackground: true, hasTrack: true, isObstructed: false, isPreparing: false)),
            ("opening a dialog or output picker", .init(isBackground: false, hasTrack: true, isObstructed: true, isPreparing: false)),
            ("losing the selected track", .init(isBackground: false, hasTrack: false, isObstructed: false, isPreparing: false))
        ]
        for (event, availability) in unavailable {
            var state = WatchImmersivePlayback()
            state.updateAvailability(frontmost, at: 0)
            let before = request(state, "before \(event)")
            state.updateAvailability(availability, at: 2)
            check(!state.isImmersive && state.idleRequest == nil, "\(event) cancels the pending deadline")
            check(!state.enter(for: before, at: 5), "\(event) invalidates a queued completion")

            state.updateAvailability(frontmost, at: 6)
            let resumed = request(state, "after \(event)")
            check(resumed.deadline == 11 && resumed != before, "returning after \(event) starts a new five seconds")
            check(!state.enter(for: before, at: 11), "the old completion stays invalid after \(event) ends")
            check(!state.enter(for: resumed, at: 10.999), "the resumed page cannot use time from before \(event)")
            check(state.enter(for: resumed, at: 11), "the resumed page enters on its own deadline")

            state.updateAvailability(availability, at: 12)
            check(!state.isImmersive && state.idleRequest == nil, "\(event) also exits an existing immersive layout")
            state.updateAvailability(frontmost, at: 13)
            check(state.idleRequest?.deadline == 18 && !state.isImmersive,
                  "after \(event) interrupts immersion, the restored controls get five seconds")
        }
    }

    private static func verifyPreparationWhileImmersive() {
        let preparing = WatchImmersivePlayback.Availability(
            isBackground: false, hasTrack: true, isObstructed: false, isPreparing: true
        )
        var state = WatchImmersivePlayback()
        state.updateAvailability(preparing, at: 0)
        check(!state.isImmersive && state.idleRequest == nil, "preparing playback does not arm an entry deadline")
        state.updateAvailability(frontmost, at: 0)
        let first = request(state, "before track preparation")
        check(state.enter(for: first, at: 5), "fixture reaches immersive playback")
        state.updateAvailability(preparing, at: 6)
        check(state.isImmersive && state.idleRequest == nil,
              "temporarily preparing the next track preserves an existing immersive presentation")
        state.updateAvailability(frontmost, at: 8)
        check(state.isImmersive && state.idleRequest == nil,
              "preparation completion keeps immersive mode without starting another timer")
        state.updateAvailability(preparing, at: 9)
        state.interact(at: 10)
        check(!state.isImmersive && state.idleRequest == nil,
              "touch during preparation restores controls without scheduling ineligible work")
        state.updateAvailability(frontmost, at: 12)
        let afterPreparation = request(state, "after interacting during preparation")
        check(afterPreparation.deadline == 17, "preparation completion after touch arms five new seconds")
        check(!state.enter(for: first, at: 17), "the pre-preparation task cannot enter after a user exit")
        check(state.enter(for: afterPreparation, at: 17), "the current post-preparation deadline can enter")
    }

    private static func verifyLayouts() {
        let sizes = [CGSize(width: 162, height: 197), CGSize(width: 176, height: 215),
                     CGSize(width: 184, height: 224), CGSize(width: 198, height: 242),
                     CGSize(width: 205, height: 251), CGSize(width: 211, height: 257)]
        let orientations: [WatchTransferOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .upsideDown]
        for physical in sizes {
            for orientation in orientations {
                let metrics = WatchSurfaceMetrics(physicalSize: physical, orientation: orientation)
                let insets = metrics.pageInsets(hasAction: true, hasTitle: false)
                let size = CGSize(width: metrics.logicalSize.width,
                                  height: metrics.logicalSize.height - insets.headerHeight)
                for captionHeight: CGFloat in [17, 20, 34, 46] {
                    let context = "\(Int(physical.width))×\(Int(physical.height)), \(orientation), caption \(captionHeight)"
                    verifyLayout(WatchImmersiveLayout(size: size, clockFrame: insets.bodyClockFrame,
                                                     titleHeight: captionHeight, centeredVertically: orientation.isLandscape),
                                 size: size, clock: insets.bodyClockFrame,
                                 titleHeight: captionHeight, centeredVertically: orientation.isLandscape, context: context)
                }
                if orientation == .portrait {
                    let legacy = WatchImmersiveLayout(size: size, clockFrame: insets.bodyClockFrame)
                    let explicit = WatchImmersiveLayout(size: size, clockFrame: insets.bodyClockFrame,
                                                       titleHeight: 34, centeredVertically: false)
                    let expectedSide = min(size.width - 24, size.height - 2 - 12 - 34 - 8)
                    check(legacy.artworkFrame == explicit.artworkFrame && legacy.titleFrame == explicit.titleFrame,
                          "\(physical): portrait uses the original default layout")
                    check(close(legacy.artworkFrame.minY, 2), "\(physical): portrait retains its original top position")
                    check(close(legacy.artworkFrame.width, expectedSide), "\(physical): portrait retains its original cover size")
                    check(close(legacy.titleFrame.minY, 2 + expectedSide + 8) && close(legacy.titleFrame.height, 34),
                          "\(physical): portrait retains the original caption position and reserved height")
                }
            }
        }
        let size = CGSize(width: 162, height: 151)
        let plain = WatchImmersiveLayout(size: size)
        let offscreen = WatchImmersiveLayout(size: size, clockFrame: CGRect(x: 72, y: -46, width: 90, height: 32))
        check(plain.artworkFrame == offscreen.artworkFrame && plain.titleFrame == offscreen.titleFrame,
              "the portrait clock above the content does not unnecessarily shrink immersive artwork")

        // A wide clock obstacle forces a narrow safe column: centering must
        // still work when available width, rather than height, limits the cover.
        let limitedSize = CGSize(width: 257, height: 211)
        let wideClock = CGRect(x: 0, y: 0, width: 100, height: 90)
        let widthLimited = WatchImmersiveLayout(size: limitedSize, clockFrame: wideClock,
                                               titleHeight: 17, centeredVertically: true)
        verifyLayout(widthLimited, size: limitedSize, clock: wideClock, titleHeight: 17,
                     centeredVertically: true, context: "width-limited landscape column")
        check(close(widthLimited.artworkFrame.width, widthLimited.titleFrame.width),
              "the narrow safe column actually limits the cover width")
        check(widthLimited.artworkFrame.minY > 12 + epsilon,
              "a width-limited cover and caption move inward together instead of sticking to the top margin")
    }

    private static func verifyLayout(_ layout: WatchImmersiveLayout, size: CGSize, clock: CGRect,
                                     titleHeight: CGFloat, centeredVertically: Bool, context: String) {
        let cover = layout.artworkFrame
        let title = layout.titleFrame
        let bounds = CGRect(origin: .zero, size: size)
        let values = [cover.minX, cover.minY, cover.width, cover.height,
                      title.minX, title.minY, title.width, title.height]
        check(values.allSatisfy(\.isFinite), context + ": every frame coordinate is finite")
        check(cover.width > 0 && close(cover.width, cover.height), context + ": artwork is a nonempty square")
        check(bounds.contains(cover), context + ": the enlarged cover stays within the content canvas")
        check(bounds.contains(title), context + ": the complete title stays within the content canvas")
        check(close(title.minY - cover.maxY, 8), context + ": the title is eight points below the cover")
        check(!overlaps(cover, title), context + ": title and cover never overlap")
        check(close(cover.midX, title.midX), context + ": cover and title are centered in the same safe column")
        check(cover.width <= title.width + epsilon, context + ": title and cover share the column width budget")
        check(!overlaps(cover, clock), context + ": the enlarged cover avoids the actual rotated system clock")
        check(!overlaps(title, clock), context + ": the title avoids the actual rotated system clock")
        check(cover.width > 54, context + ": the cover grows beyond both normal 40pt and 54pt artwork sizes")
        check(close(title.height, titleHeight), context + ": the requested caption height remains available")
        check(title.minX >= 12 - epsilon && title.maxX <= size.width - 12 + epsilon,
              context + ": caption keeps curved-edge horizontal breathing room")
        check(title.maxY <= size.height - 12 + epsilon, context + ": the title retains bottom breathing room")
        if centeredVertically {
            let group = cover.union(title)
            check(close(group.midY, size.height / 2),
                  context + ": the actual cover and caption group is vertically centered")
            check(close(cover.minY, size.height - title.maxY),
                  context + ": the visible group has equal top and bottom margins")
            check(cover.minY >= 12 - epsilon,
                  context + ": centering preserves at least twelve points above the cover")
        }
    }

    private static func request(_ state: WatchImmersivePlayback, _ context: String) -> WatchImmersivePlayback.IdleRequest {
        guard let request = state.idleRequest else {
            FileHandle.standardError.write(Data(("FAIL: expected a pending deadline: " + context + "\n").utf8))
            exit(1)
        }
        return request
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        guard !a.isNull && !b.isNull else { return false }
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > epsilon && intersection.height > epsilon
    }

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < epsilon }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }
}
