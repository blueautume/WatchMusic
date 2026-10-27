import Foundation

/// Byte counts are derived from the system's file-transfer fraction and file size.
/// Speed and remaining time are estimates of recent progress, never a guarantee
/// of the system's background scheduling or the watch's save confirmation.
struct TransferMetrics: Equatable {
    let completedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double?
    let estimatedTimeRemaining: TimeInterval?
    let isTransferring: Bool
}

/// Uses monotonic timestamps so wall-clock changes cannot distort estimates.
struct TransferProgressSampler {
    private struct Sample {
        let time: TimeInterval
        let bytes: Int64
    }

    private let window: TimeInterval = 8
    private let staleAfter: TimeInterval = 4
    private var samples: [Sample] = []
    private var lastTotal: Int64?
    private var lastAdvance: TimeInterval?

    mutating func sample(completedBytes: Int64, totalBytes: Int64,
                         isTransferring: Bool, at time: TimeInterval) -> TransferMetrics {
        let total = max(0, totalBytes)
        let completed = min(total, max(0, completedBytes))
        let unknown = TransferMetrics(completedBytes: completed, totalBytes: total,
                                      bytesPerSecond: nil, estimatedTimeRemaining: nil,
                                      isTransferring: false)
        guard time.isFinite, total > 0, completed < total, isTransferring else {
            reset()
            return unknown
        }

        // A process resume, unit reset, or new file size invalidates old samples.
        if let previous = samples.last,
           lastTotal != total || completed < previous.bytes || time < previous.time || time - previous.time > staleAfter {
            reset()
        }
        lastTotal = total
        guard let previous = samples.last else {
            samples = [Sample(time: time, bytes: completed)]
            return unknown
        }

        if completed > previous.bytes {
            // Once a transfer stalls, collect a fresh interval before estimating.
            if let lastAdvance, time - lastAdvance >= staleAfter {
                samples = [previous]
            }
            lastAdvance = time
        }
        if time > previous.time {
            samples.append(Sample(time: time, bytes: completed))
        }
        while samples.count > 2, samples[1].time < time - window {
            samples.removeFirst()
        }

        guard let lastAdvance, time - lastAdvance < staleAfter else {
            return unknown
        }
        guard let first = samples.first, time - first.time >= 1 else {
            return TransferMetrics(completedBytes: completed, totalBytes: total,
                                   bytesPerSecond: nil, estimatedTimeRemaining: nil,
                                   isTransferring: true)
        }
        let rate = Double(completed - first.bytes) / (time - first.time)
        guard rate.isFinite, rate > 0 else { return unknown }
        return TransferMetrics(completedBytes: completed, totalBytes: total,
                               bytesPerSecond: rate,
                               estimatedTimeRemaining: Double(total - completed) / rate,
                               isTransferring: true)
    }

    private mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastTotal = nil
        lastAdvance = nil
    }
}
