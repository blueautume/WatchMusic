import Foundation

@main
struct TransferMetricsTests {
    static func main() {
        var sampler = TransferProgressSampler()
        let waiting = sampler.sample(completedBytes: 0, totalBytes: 10_000, isTransferring: true, at: 0)
        expect(waiting.bytesPerSecond == nil && !waiting.isTransferring, "A queued transfer must not invent a speed")
        let moving = sampler.sample(completedBytes: 1_000, totalBytes: 10_000, isTransferring: true, at: 1)
        expect(moving.bytesPerSecond == 1_000 && moving.estimatedTimeRemaining == 9 && moving.isTransferring,
               "A real progress delta supplies rate and remaining time")
        _ = sampler.sample(completedBytes: 2_000, totalBytes: 10_000, isTransferring: true, at: 2)
        _ = sampler.sample(completedBytes: 2_000, totalBytes: 10_000, isTransferring: true, at: 3)
        _ = sampler.sample(completedBytes: 2_000, totalBytes: 10_000, isTransferring: true, at: 4)
        _ = sampler.sample(completedBytes: 2_000, totalBytes: 10_000, isTransferring: true, at: 5)
        let stalled = sampler.sample(completedBytes: 2_000, totalBytes: 10_000, isTransferring: true, at: 6)
        expect(stalled.bytesPerSecond == nil && stalled.estimatedTimeRemaining == nil && !stalled.isTransferring,
               "A stalled transfer hides stale estimates")
        let resumed = sampler.sample(completedBytes: 3_000, totalBytes: 10_000, isTransferring: true, at: 7)
        expect(resumed.bytesPerSecond == 1_000, "A resumed transfer starts a fresh recent estimate")
        let reset = sampler.sample(completedBytes: 500, totalBytes: 10_000, isTransferring: true, at: 8)
        expect(reset.bytesPerSecond == nil && !reset.isTransferring, "Counter regression discards old samples")
        let sizeChange = sampler.sample(completedBytes: 1_000, totalBytes: 20_000, isTransferring: true, at: 9)
        expect(sizeChange.bytesPerSecond == nil, "A new total invalidates prior estimates")
        let processResume = sampler.sample(completedBytes: 3_000, totalBytes: 20_000, isTransferring: true, at: 30)
        expect(processResume.bytesPerSecond == nil, "A long sampling gap cannot fabricate a current speed")
        let complete = sampler.sample(completedBytes: 25_000, totalBytes: 20_000, isTransferring: true, at: 31)
        expect(complete.completedBytes == 20_000 && complete.bytesPerSecond == nil && !complete.isTransferring,
               "Completed bytes clamp to total while save confirmation remains separate")
        let cancelled = sampler.sample(completedBytes: 1_000, totalBytes: 20_000, isTransferring: false, at: 32)
        expect(cancelled.bytesPerSecond == nil && !cancelled.isTransferring, "Cancelled work has no active estimate")
        let unknown = sampler.sample(completedBytes: 1_000, totalBytes: 0, isTransferring: true, at: 33)
        expect(unknown.completedBytes == 0 && unknown.bytesPerSecond == nil, "Unknown lengths do not yield rates")
        _ = sampler.sample(completedBytes: 100, totalBytes: 1_000, isTransferring: true, at: 40)
        let clockReset = sampler.sample(completedBytes: 200, totalBytes: 1_000, isTransferring: true, at: 39)
        expect(clockReset.bytesPerSecond == nil, "A backward timestamp resets the sampler")
        print("Transfer metrics tests passed")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}
