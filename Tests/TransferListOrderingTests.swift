import Foundation

@main
struct TransferListOrderingTests {
    struct Record: TransferListRecord {
        let id: String
        let state: TransferRecordState
        let createdAt: Date
        let totalBytes: Int64 = 10_000

        init(_ id: String, _ state: TransferRecordState, _ time: TimeInterval) {
            self.id = id; self.state = state; createdAt = Date(timeIntervalSince1970: time)
        }
    }

    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func metrics(_ bytes: Int64, transferring: Bool = false) -> TransferMetrics {
        TransferMetrics(completedBytes: bytes, totalBytes: 10_000, bytesPerSecond: nil,
                        estimatedTimeRemaining: nil, isTransferring: transferring)
    }

    static func main() throws {
        let records: [Record] = [
            Record("stored-new", .stored, 100), Record("waiting-new", .queued, 90),
            Record("failed-old", .failed, 10), Record("partial", .queued, 80),
            Record("confirming", .awaitingReceipt, 70), Record("waiting-old", .queued, 20),
            Record("cancelled-new", .cancelled, 110), Record("outdated", .outdated, 60),
            Record("stored-old", .stored, 5)
        ]
        let originalIDs = records.map(\.id)
        let active = TransferListOrdering.activeTransfers(records, metrics: ["partial": metrics(500)])
        expect(active.map(\.id) == ["partial", "confirming", "waiting-old", "waiting-new", "outdated", "failed-old"],
               "Partial work precedes save confirmation, FIFO waiting, and recent issues")
        expect(TransferListOrdering.storedTransfers(records).map(\.id) == ["stored-new", "stored-old"],
               "Only verified stored records belong to the completed list, newest first")
        expect(records.map(\.id) == originalIDs, "Rendering lists must not reorder persisted newest-first history")
        expect(Set(active.map(\.id)).union(TransferListOrdering.storedTransfers(records).map(\.id)) == Set(records.filter { $0.state != .cancelled }.map(\.id)),
               "Failures, outdated items, and pending confirmations remain visible while cancelled history is omitted")
        expect(!active.contains { $0.state == .cancelled } && !TransferListOrdering.storedTransfers(records).contains { $0.state == .cancelled },
               "Cancelled history belongs to neither the in-progress tab nor the stored tab")
        expect(records.map(\.id) == originalIDs && records.contains { $0.id == "cancelled-new" && $0.state == .cancelled },
               "Hiding cancelled rows must preserve their original history and source order")

        let queued = [Record("waiting", .queued, 0), Record("moving", .queued, 20)]
        expect(TransferListOrdering.activeTransfers(queued, metrics: ["moving": metrics(0, transferring: true)]).first?.id == "moving",
               "Native activity can rank a transfer before the first byte count arrives")
        expect(TransferListOrdering.activeTransfers(queued, metrics: ["moving": metrics(50)]).first?.id == "moving",
               "A stalled or paused transfer stays ahead after isTransferring becomes false")
        expect(TransferListOrdering.activeTransfers(queued, completedBytes: ["moving": 50]).first?.id == "moving",
               "Real LAN bytes still rank activity before speed samples exist")
        expect(TransferListOrdering.activeTransfers(queued, metrics: ["moving": metrics(0)]).first?.id == "waiting",
               "A zero-byte sampler with no activity does not promote waiting work")
        let completeBytes = [Record("full", .queued, 0), Record("partial", .queued, 30), Record("waiting", .queued, 10)]
        expect(TransferListOrdering.activeTransfers(completeBytes, metrics: ["full": metrics(10_000, transferring: true), "partial": metrics(1_000)]).map(\.id) == ["partial", "full", "waiting"],
               "A late native completion callback cannot place 100% sent bytes before ongoing partial work")
        expect(TransferListOrdering.activeTransfers(completeBytes, completedBytes: ["full": 10_000, "partial": 1_000]).map(\.id) == ["partial", "full", "waiting"],
               "Complete LAN bytes also sort with confirmation ahead of queued work")
        expect(TransferListOrdering.storedTransfers(completeBytes).isEmpty,
               "A complete byte count alone never moves a queued record into stored history")

        // Old WC and LAN awaitingReceipt states both require a save fact; neither
        // 100% byte counts nor a previous failed state prove successful storage.
        let confirming = Record("legacy-confirming", try JSONDecoder().decode(TransferRecordState.self, from: Data("\"awaitingReceipt\"".utf8)), 50)
        let history = [Record("failed", .failed, 100), confirming, Record("stored", .stored, 25)]
        expect(TransferListOrdering.activeTransfers(history, metrics: ["legacy-confirming": metrics(10_000)]).map(\.id) == ["legacy-confirming", "failed"],
               "Legacy save confirmation stays ongoing even when all bytes were sent")
        expect(TransferListOrdering.storedTransfers(history).map(\.id) == ["stored"],
               "A historical failure or waiting receipt never becomes a completed transfer")
        let twoMoving = [Record("moving-new", .queued, 30), Record("paused-old", .queued, 10)]
        expect(TransferListOrdering.activeTransfers(twoMoving, metrics: ["moving-new": metrics(9_000, transferring: true), "paused-old": metrics(1)]).map(\.id) == ["paused-old", "moving-new"],
               "Activity order stays FIFO instead of jumping as speed or byte counts change")
        let confirmations = [Record("confirm-new", .awaitingReceipt, 30), Record("confirm-old", .awaitingReceipt, 10)]
        expect(TransferListOrdering.activeTransfers(confirmations).map(\.id) == ["confirm-old", "confirm-new"],
               "Save confirmations retain FIFO order")

        for state in [TransferRecordState.queued, .awaitingReceipt, .stored, .failed, .cancelled, .outdated] {
            let issue = state == .failed || state == .cancelled || state == .outdated
            expect(TransferListOrdering.canClearUnfinished(state, isLive: false) == issue,
                   "Issue cleanup preserves pending work and stored history")
            expect(!TransferListOrdering.canClearUnfinished(state, isLive: true),
                   "Issue cleanup cannot remove a record still owned by a live transfer")
        }

        // Equal timestamps need deterministic IDs independent of dictionary or
        // source-array iteration order, including an entire multi-file batch.
        let ties = [Record("z", .queued, 20), Record("b", .queued, 20), Record("a", .queued, 20)]
        for input in [ties, Array(ties.reversed())] {
            expect(TransferListOrdering.activeTransfers(input).map(\.id) == ["a", "b", "z"],
                   "Equal-time waiting records have a deterministic ID tie-break")
            expect(TransferListOrdering.activeTransfers(input, completedBytes: ["a": 1, "b": 1, "z": 1]).map(\.id) == ["a", "b", "z"],
                   "Equal-time active records have the same deterministic tie-break")
        }
        let storedTies = [Record("z", .stored, 20), Record("a", .stored, 20)]
        expect(TransferListOrdering.storedTransfers(storedTies).map(\.id) == ["a", "z"],
               "Completed equal-time records also sort deterministically")
        let issueTies = [Record("z", .failed, 20), Record("a", .cancelled, 20), Record("b", .outdated, 20)]
        expect(TransferListOrdering.activeTransfers(issueTies).map(\.id) == ["b", "z"],
               "Visible retryable issues use stable IDs while cancelled history stays hidden")

        let falselyActiveTerminal = [Record("failed", .failed, 100), Record("waiting", .queued, 5), Record("confirming", .awaitingReceipt, 10)]
        expect(TransferListOrdering.activeTransfers(falselyActiveTerminal,
                                                   metrics: ["failed": metrics(900, transferring: true), "confirming": metrics(10_000, transferring: true)]).map(\.id) == ["confirming", "waiting", "failed"],
               "Stale metrics cannot promote a failed record or classify confirmation as active bytes")
        expect(TransferListOrdering.activeTransfers([Record("stored", .stored, 0)]).isEmpty,
               "A fully stored history has no ongoing entries")
        expect(TransferListOrdering.storedTransfers([] as [Record]).isEmpty, "An empty history has no completed entries")
        print("PASS: \(assertions) transfer list ordering and grouping assertions")
    }
}
