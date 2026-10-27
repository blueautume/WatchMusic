import Foundation

@main
struct PlaybackQueueTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        // Boundaries must not manufacture a playable index for a missing track.
        for mode in PlaybackMode.allCases {
            for completed in [false, true] {
                expect(PlaybackQueueLogic.nextIndex(current: 0, count: 0, mode: mode, completed: completed) == nil, "empty queue / \(mode)")
                expect(PlaybackQueueLogic.nextIndex(current: -1, count: 3, mode: mode, completed: completed) == nil, "negative current / \(mode)")
                expect(PlaybackQueueLogic.nextIndex(current: 3, count: 3, mode: mode, completed: completed) == nil, "deleted or out of range current / \(mode)")
                expect(PlaybackQueueLogic.nextIndex(current: 0, count: -1, mode: mode, completed: completed) == nil, "negative count / \(mode)")
            }
        }
        expect(PlaybackQueueLogic.previousIndex(current: 0, count: 0) == nil, "previous empty")
        expect(PlaybackQueueLogic.previousIndex(current: -1, count: 3) == nil, "previous negative index")
        expect(PlaybackQueueLogic.previousIndex(current: 3, count: 3) == nil, "previous deleted index")

        // Automatic completion and explicit next have deliberately different semantics.
        for count in 1...50 {
            for current in 0..<count {
                let advanced = (current + 1) % count
                expect(PlaybackQueueLogic.nextIndex(current: current, count: count, mode: .sequential, completed: true) == (current + 1 < count ? current + 1 : nil), "sequential finish count=\(count), current=\(current)")
                expect(PlaybackQueueLogic.nextIndex(current: current, count: count, mode: .repeatAll, completed: true) == advanced, "repeat list wraps")
                expect(PlaybackQueueLogic.nextIndex(current: current, count: count, mode: .repeatOne, completed: true) == current, "repeat one auto repeats")
                for mode in [PlaybackMode.sequential, .repeatAll, .repeatOne] {
                    expect(PlaybackQueueLogic.nextIndex(current: current, count: count, mode: mode, completed: false) == advanced, "manual next advances even in repeat one")
                }
                expect(PlaybackQueueLogic.previousIndex(current: current, count: count) == (current + count - 1) % count, "previous wraps to last")
            }
        }

        // A shuffle choice may be random, but it must stay in range and avoid the
        // just-finished track whenever an alternative exists.
        for count in 1...20 {
            for current in 0..<count {
                for completed in [false, true] {
                    for _ in 0..<30 {
                        let next = PlaybackQueueLogic.nextIndex(current: current, count: count, mode: .shuffle, completed: completed)
                        expect(next != nil, "shuffle returns a choice")
                        guard let next else { continue }
                        expect((0..<count).contains(next), "shuffle index remains valid")
                        expect(count == 1 ? next == 0 : next != current, "shuffle avoids immediate repeat")
                    }
                }
            }
        }
        print("PASS: \(assertions) playback queue assertions")
    }
}
