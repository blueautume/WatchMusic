@main struct WatchDisplayActivityTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ description: String) {
            precondition(condition, description)
            count += 1
        }
        func inputs(_ charging: Bool, _ receiving: Bool, _ frontmost: Bool = true) -> WatchDisplayActivityState.Inputs {
            .init(isCharging: charging, isReceiving: receiving, isFrontmost: frontmost)
        }
        var state = WatchDisplayActivityState()
        check(state.update(inputs(false, false)) == nil, "normal use creates no display request")
        check(state.update(inputs(true, false)) == .begin, "charging inside any page begins one request")
        check(state.update(inputs(true, false)) == nil, "power polling cannot create duplicate tokens")
        check(state.update(inputs(true, true)) == nil, "starting transfer reuses an existing charging request")
        check(state.update(inputs(false, true)) == nil && state.isRequested, "unplugging does not end an ongoing transfer request")
        check(state.update(inputs(false, false)) == .end, "unplugged completion ends its request exactly once")
        check(state.update(inputs(false, false)) == nil, "repeated completion cannot end a second token")
        check(state.update(inputs(false, true)) == .begin, "receiving without power begins a transfer request")
        check(state.update(inputs(false, true, false)) == .end, "leaving the app releases the request during a transfer")
        check(state.update(inputs(true, true, false)) == nil && !state.isRequested, "charging in the background cannot reacquire a request")
        check(state.update(inputs(true, true)) == .begin, "returning frontmost while charging recreates one request")
        check(state.update(inputs(true, false)) == nil && state.isRequested, "transfer completion retains the charging request")
        check(state.update(inputs(true, false, false)) == .end, "leaving a charging app ends its request")
        check(state.update(inputs(false, false, false)) == nil, "unplugging an already stopped app stays stopped")
        print("PASS: \(count) Watch display activity lifecycle assertions")
    }
}
