import Foundation

protocol TransferListRecord {
    var id: String { get }
    var state: TransferRecordState { get }
    var createdAt: Date { get }
    var totalBytes: Int64 { get }
}

/// Display ordering is independent of persisted history, whose newest-first
/// order is still used to determine the latest transfer for each local song.
enum TransferListOrdering {
    static func canClearUnfinished(_ state: TransferRecordState, isLive: Bool) -> Bool {
        guard !isLive else { return false }
        return state == .failed || state == .cancelled || state == .outdated
    }

    static func activeTransfers<Record: TransferListRecord>(
        _ records: [Record], metrics: [String: TransferMetrics] = [:],
        completedBytes: [String: Int64] = [:]
    ) -> [Record] {
        records.filter { $0.state != .stored && $0.state != .cancelled }.sorted { lhs, rhs in
            let left = priority(lhs, metrics: metrics, completedBytes: completedBytes)
            let right = priority(rhs, metrics: metrics, completedBytes: completedBytes)
            if left != right { return left < right }
            if lhs.createdAt != rhs.createdAt {
                // Pending work is FIFO; terminal issues show the latest first.
                return left == 3 ? lhs.createdAt > rhs.createdAt : lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    static func storedTransfers<Record: TransferListRecord>(_ records: [Record]) -> [Record] {
        records.filter { $0.state == .stored }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    private static func priority<Record: TransferListRecord>(
        _ record: Record, metrics: [String: TransferMetrics], completedBytes: [String: Int64]
    ) -> Int {
        switch record.state {
        case .queued:
            let received = max(completedBytes[record.id] ?? 0, metrics[record.id]?.completedBytes ?? 0)
            if record.totalBytes > 0, received >= record.totalBytes { return 1 }
            // A paused transfer keeps its place even after rate estimates stale.
            return received > 0 || metrics[record.id]?.isTransferring == true ? 0 : 2
        case .awaitingReceipt: return 1
        case .failed, .cancelled, .outdated: return 3
        case .stored: return 4
        }
    }
}
