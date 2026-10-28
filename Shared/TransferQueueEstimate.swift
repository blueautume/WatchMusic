import Foundation

/// Estimates the serial queue from measured throughput, rather than adding
/// per-file ETAs (waiting songs do not yet have a throughput of their own).
struct TransferQueueEstimate {
    struct Item {
        let id: String
        let state: TransferRecordState
        let totalBytes: Int64
        let completedBytes: Int64
    }

    private let publicationInterval: TimeInterval = 15
    private let rateCarryInterval: TimeInterval = 8
    private var smoothedRate: Double?
    private var lastRateTime: TimeInterval?
    private var lastPublication: TimeInterval?
    private(set) var remainingSeconds: TimeInterval?
    private(set) var label: String?

    mutating func update(items: [Item], metrics: [String: TransferMetrics],
                         isAdvancing: Bool, hasUnpreparedWork: Bool = false,
                         at time: TimeInterval) -> String? {
        guard time.isFinite else { reset(); return nil }
        if let lastRateTime, time < lastRateTime { reset() }
        let pending = items.filter { $0.state.isPending }
        guard !pending.isEmpty, !hasUnpreparedWork,
              !pending.contains(where: { $0.state == .paused || $0.totalBytes <= 0 }) else {
            reset(); return nil
        }
        guard isAdvancing else { clearPresentation(); return nil }

        let rates = pending.compactMap { item -> Double? in
            guard item.state == .queued, let measurement = metrics[item.id], measurement.isTransferring,
                  let rate = measurement.bytesPerSecond, rate.isFinite, rate > 0 else { return nil }
            return min(rate, 1_000_000_000_000)
        }
        let measuredRate = rates.reduce(0, +)
        if measuredRate > 0, measuredRate.isFinite {
            if let previous = smoothedRate, let previousTime = lastRateTime,
               time - previousTime <= rateCarryInterval {
                // Time-weighted smoothing is independent of callback frequency.
                let weight = min(0.35, max(0, 1 - exp(-(time - previousTime) / 8)))
                smoothedRate = previous + weight * (measuredRate - previous)
            } else { smoothedRate = measuredRate }
            lastRateTime = time
        }
        guard let rate = smoothedRate, rate > 0, rate.isFinite,
              let lastRateTime, time - lastRateTime <= rateCarryInterval else {
            clearPresentation(); return nil
        }

        let remaining = pending.reduce(0.0) { total, item in
            let completed = item.state == .awaitingReceipt ? item.totalBytes
                : min(item.totalBytes, max(0, item.completedBytes))
            return total + Double(item.totalBytes - completed)
        }
        let seconds = remaining / rate
        guard seconds.isFinite, seconds > 0 else { clearPresentation(); return nil }
        remainingSeconds = seconds
        let candidate = Self.format(seconds)
        if label == nil || lastPublication == nil || time - (lastPublication ?? time) >= publicationInterval {
            if label != candidate {
                label = candidate
                lastPublication = time
            }
        }
        return label
    }

    mutating func reset() {
        smoothedRate = nil
        lastRateTime = nil
        clearPresentation()
    }

    private mutating func clearPresentation() {
        label = nil
        remainingSeconds = nil
        lastPublication = nil
    }

    private static func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "剩余不到 1 分钟" }
        if seconds >= 86_400 { return "剩余超过 1 天" }
        let unit = seconds <= 300 ? 60.0 : (seconds <= 3_600 ? 300.0 : 900.0)
        let minutes = Int(ceil(seconds / unit) * unit / 60)
        if minutes < 60 { return "剩余约 \(minutes) 分钟" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "剩余约 \(hours) 小时" : "剩余约 \(hours) 小时 \(remainder) 分钟"
    }
}
