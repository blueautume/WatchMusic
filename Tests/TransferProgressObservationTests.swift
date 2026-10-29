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
        progress.update(values: [:], metrics: [:], remainingEstimate: nil)
        precondition(notifications == 3 && progress.remainingEstimate == nil, "Clearing replaces every transient value together")
        withExtendedLifetime(observation) {}
        print("PASS: 5 isolated transfer observation assertions")
    }
}
