import Foundation

@main
struct TransferQueueEstimateTests {
    private static var assertions = 0
    static func main() {
        func item(_ id: String, _ total: Int64, _ completed: Int64 = 0,
                  _ state: TransferRecordState = .queued) -> TransferQueueEstimate.Item {
            .init(id: id, state: state, totalBytes: total, completedBytes: completed)
        }
        func metrics(_ completed: Int64, _ total: Int64, _ speed: Double?, moving: Bool = true) -> TransferMetrics {
            .init(completedBytes: completed, totalBytes: total, bytesPerSecond: speed,
                  estimatedTimeRemaining: nil, isTransferring: moving)
        }
        var estimate = TransferQueueEstimate()
        let first = item("a", 60_000, 10_000)
        let second = item("b", 120_000)
        let rate = ["a": metrics(10_000, 60_000, 1_000)]
        check(estimate.update(items: [first, second], metrics: rate, isAdvancing: true, at: 1) == "剩余约 3 分钟",
              "A waiting song contributes all remaining bytes at the active lane rate")
        check(estimate.remainingSeconds == 170, "The aggregate uses current plus queued bytes, not just the active file")
        let nearlyDone = [item("a", 60_000, 55_000)]
        check(estimate.update(items: nearlyDone, metrics: rate, isAdvancing: true, at: 14) == "剩余约 3 分钟",
              "Progress cannot change the displayed approximation within fifteen seconds")
        check(estimate.update(items: nearlyDone, metrics: rate, isAdvancing: true, at: 16) == "剩余不到 1 分钟",
              "The next real event after fifteen seconds can change the approximation")
        check(estimate.update(items: [item("b", 120_000)], metrics: ["b": metrics(0, 120_000, nil)],
                              isAdvancing: true, at: 17) != nil,
              "A recent measured lane rate carries across the next song's initial samples")
        check(estimate.update(items: [second], metrics: [:], isAdvancing: true, at: 30) == nil,
              "A rate cannot be carried indefinitely when the new song supplies no measurement")
        check(estimate.update(items: [item("b", 120_000, 0, .paused)], metrics: rate,
                              isAdvancing: true, at: 31) == nil,
              "Any paused queued work makes a total completion time unknowable")
        check(estimate.update(items: [second], metrics: [:], isAdvancing: true, at: 32) == nil,
              "Resuming after a pause requires a new measured rate")
        check(estimate.update(items: [item("a", 0), second], metrics: rate, isAdvancing: true, at: 33) == nil,
              "An unknown file length never produces a partial total ETA")
        check(estimate.update(items: [first], metrics: rate, isAdvancing: true, hasUnpreparedWork: true, at: 34) == nil,
              "Songs still being prepared cannot be omitted from an apparently complete total")
        check(estimate.update(items: [first], metrics: rate, isAdvancing: true, at: 35) != nil,
              "A valid fresh measurement restores the estimate immediately")
        check(estimate.update(items: [first], metrics: rate, isAdvancing: false, at: 36) == nil,
              "A one-shot stall invalidation hides the stale estimate")
        check(estimate.update(items: [item("a", 60_000, 60_000, .awaitingReceipt)], metrics: rate,
                              isAdvancing: true, at: 37) == nil,
              "Verification-only work does not invent a save-confirmation ETA")
        check(estimate.update(items: [item("a", 60_000, 0, .failed)], metrics: rate,
                              isAdvancing: true, at: 38) == nil,
              "Retryable terminal records are not included as running work")
        check(estimate.update(items: [], metrics: rate, isAdvancing: true, at: 39) == nil,
              "An empty queue clears the estimate")

        var smooth = TransferQueueEstimate()
        _ = smooth.update(items: [first], metrics: rate, isAdvancing: true, at: 100)
        _ = smooth.update(items: [first], metrics: ["a": metrics(10_000, 60_000, 10_000)], isAdvancing: true, at: 101)
        check((smooth.remainingSeconds ?? 0) > 15 && (smooth.remainingSeconds ?? 100) < 50,
              "A one-second throughput spike is smoothed rather than immediately trusted")
        _ = smooth.update(items: [first], metrics: rate, isAdvancing: true, at: 50)
        check(smooth.remainingSeconds == 50, "A backwards monotonic timestamp resets the old smoothing history")
        check(smooth.update(items: [first], metrics: rate, isAdvancing: true, at: .nan) == nil,
              "Non-finite time is rejected")
        check(smooth.update(items: [first], metrics: ["a": metrics(10_000, 60_000, .infinity)],
                            isAdvancing: true, at: 200) == nil,
              "An invalid native speed cannot fabricate an estimate")
        let huge = [item("a", Int64.max), item("b", Int64.max)]
        check(smooth.update(items: huge, metrics: ["a": metrics(0, Int64.max, 1)], isAdvancing: true, at: 201) == "剩余超过 1 天",
              "Very large queues neither overflow byte aggregation nor duration formatting")
        print("PASS: \(assertions) serial queue estimate assertions")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError(message) }
    }
}
