import Combine
import Foundation

@main
struct TransferProgressObservationTests {
    @MainActor static func main() {
        let progress = PhoneTransferProgress()
        var notifications = 0
        let observation = progress.objectWillChange.sink { notifications += 1 }
        let measured = TransferMetrics(completedBytes: 5, totalBytes: 10, bytesPerSecond: 1,
                                       estimatedTimeRemaining: 5, isTransferring: true)
        progress.update(values: ["a": 0.5], metrics: ["a": measured], remainingEstimate: "剩余不到 1 分钟")
        precondition(notifications == 1, "A whole event publishes one local update")
        progress.update(values: ["a": 0.5], metrics: ["a": measured], remainingEstimate: "剩余不到 1 分钟")
        precondition(notifications == 1, "Identical measurements publish nothing")
        progress.replaceValues(["a": 0.5])
        progress.replaceMetrics(["a": measured])
        precondition(notifications == 1, "Legacy setters also suppress unchanged values")
        progress.replaceValues(["a": 0.6])
        precondition(notifications == 2 && progress.values["a"] == 0.6, "Legacy writes update the same observable storage")
        progress.recordSourceBytes(10, for: "a")
        precondition(progress.sourceBytes["a"] == 10 && progress.values["a"] == 0.6 && progress.metrics["a"] == measured,
                     "Even a complete source send cannot advance Watch-confirmed progress or create a save receipt")
        let sourceNotifications = notifications
        progress.recordSourceBytes(5, for: "a")
        precondition(notifications == sourceNotifications && progress.sourceBytes["a"] == 10,
                     "A range retry cannot inflate or regress the source's logical file position")
        progress.resetSourceBytes(for: ["a"])
        progress.recordSourceBytes(2, for: "a")
        precondition(progress.sourceBytes["a"] == 2 && progress.values["a"] == 0.6,
                     "A new source session can reset its measurement without resetting the Watch's independent receipt")
        progress.recordSourceBytes(3, for: "b")
        progress.retainSourceBytes(for: ["a"])
        precondition(progress.sourceBytes == ["a": 2], "Pruning cleared tasks also removes their transient source measurements")
        let beforeClear = notifications
        progress.update(values: [:], metrics: [:], remainingEstimate: nil)
        precondition(notifications == beforeClear + 1 && progress.remainingEstimate == nil, "Clearing replaces every confirmed transient value together")
        withExtendedLifetime(observation) {}
        print("PASS: 9 isolated transfer observation assertions")
    }
}
