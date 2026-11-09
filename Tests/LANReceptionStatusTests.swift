import Foundation

@main
struct LANReceptionStatusTests {
    private static var assertions = 0
    private static let acceptedAt = Date(timeIntervalSince1970: 1_700_000_000)

    static func main() throws {
        try concurrentAndWeightedProgress()
        try mixedTerminalOutcomes()
        try pausedAndCachedFiles()
        try legacyPreviewAndBounds()
        print("PASS: \(assertions) LAN reception batch snapshot assertions")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "LANReceptionStatusTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        assertions += 1
    }

    private static func initial(_ sizes: [Int64]) -> LANBackgroundTransferState {
        let files = sizes.enumerated().map { index, size in
            LANTransferFile(id: UUID().uuidString, folder: "目录\(index)",
                fileName: index == 0 || index == sizes.count - 1 ? "同名.mp3" : "歌曲\(index).flac",
                byteCount: size, sha256: String(repeating: "a", count: 64))
        }
        let offer = LANTransferOffer(sessionID: UUID().uuidString, token: String(repeating: "b", count: 64),
            baseURLs: [URL(string: "http://192.168.1.5:49152")!], expiresAt: acceptedAt.addingTimeInterval(900), files: files)
        return LANBackgroundTransferState(offer: offer, acceptedAt: acceptedAt)
    }

    private static func downloaded(_ id: String, in state: inout LANBackgroundTransferState) {
        _ = state.recordDownloaded(fileID: id, stagingName: UUID().uuidString + ".download")
    }

    private static func concurrentAndWeightedProgress() throws {
        var state = initial([100, 900])
        let ids = state.offer.files.map(\.id)
        let waiting = LANReceptionStatus(state: state)
        try expect(waiting.files.map(\.id) == ids && waiting.fileCount == 2, "Every queued file appears once in original manifest order")
        try expect(waiting.queuedCount == 2 && waiting.pendingCount == 2 && waiting.batchReceivedBytes == 0,
                   "An accepted batch starts with all files queued, not an invented current success")
        try expect(waiting.files[0].fileName == waiting.files[1].fileName && waiting.files[0].id != waiting.files[1].id,
                   "Identical names in different folders retain distinct stable row identities")

        _ = state.recordProgress(fileID: ids[0], bytes: 50)
        _ = state.recordProgress(fileID: ids[1], bytes: 450)
        let parallel = LANReceptionStatus(state: state)
        try expect(parallel.downloadingCount == 2 && parallel.queuedCount == 0, "Concurrent downloads remain two independent downloading rows")
        try expect(parallel.batchTotalBytes == 1_000 && parallel.batchReceivedBytes == 500 && parallel.batchProgress == 0.5,
                   "Batch receive progress sums real bytes across all concurrent downloads")
        try expect(parallel.files.map(\.id) == ids && waiting.batchReceivedBytes == 0,
                   "New observations preserve manifest order without mutating an earlier snapshot")

        downloaded(ids[0], in: &state)
        state.items[ids[1]]?.phase = .queued
        state.items[ids[1]]?.receivedBytes = 0
        let uneven = LANReceptionStatus(state: state)
        try expect(uneven.batchProgress == 0.1 && uneven.batchReceivedBytes == 100,
                   "A completed small file contributes ten percent, not the average of two file percentages")
        try expect(uneven.validatingCount == 1 && uneven.storedCount == 0 && uneven.pendingCount == 2,
                   "Downloaded data awaiting validation remains pending and cannot count as stored")
        try expect(uneven.focusedFileID == ids[0] && uneven.isSaving && uneven.totalBytes == 100,
                   "Legacy focused-file observation still identifies the validating file")

        _ = state.recordProgress(fileID: ids[1], bytes: 900)
        let received = LANReceptionStatus(state: state)
        try expect(received.batchProgress == 1 && received.storedCount == 0 && !received.allStored && !received.isFinished,
                   "Receiving every byte cannot claim a saved or finished batch")
        downloaded(ids[1], in: &state)
        let validating = LANReceptionStatus(state: state)
        try expect(validating.validatingCount == 2 && validating.pendingCount == 2 && validating.storedCount == 0,
                   "Multiple completed files can await serialized validation without disappearing")
        _ = state.recordTerminal(fileID: ids[0], kind: .stored)
        let partiallySaved = LANReceptionStatus(state: state)
        try expect(partiallySaved.storedCount == 1 && partiallySaved.pendingCount == 1 && !partiallySaved.allStored,
                   "Only the file with an explicit stored result contributes to the success count")
        _ = state.recordTerminal(fileID: ids[1], kind: .stored)
        let saved = LANReceptionStatus(state: state)
        try expect(saved.isFinished && saved.allStored && saved.storedCount == 2 && saved.batchProgress == 1,
                   "All files are successful only after each receives its stored result")
    }

    private static func mixedTerminalOutcomes() throws {
        var state = initial([100, 900, 400, 300, 600, 800])
        let ids = state.offer.files.map(\.id)
        downloaded(ids[0], in: &state)
        _ = state.recordTerminal(fileID: ids[0], kind: .stored)
        _ = state.recordProgress(fileID: ids[1], bytes: 450)
        _ = state.recordTerminal(fileID: ids[1], kind: .failed)
        _ = state.recordProgress(fileID: ids[2], bytes: 100)
        _ = state.recordTerminal(fileID: ids[2], kind: .cancelled)
        _ = state.recordProgress(fileID: ids[3], bytes: 150)
        _ = state.setPaused(fileID: ids[3], paused: true, revision: 1)
        downloaded(ids[4], in: &state)
        _ = state.recordProgress(fileID: ids[5], bytes: 200)
        let snapshot = LANReceptionStatus(state: state)
        try expect(snapshot.files.map(\.id) == ids && snapshot.files.map(\.phase) == [.stored, .failed, .cancelled, .paused, .validating, .downloading],
                   "Mixed outcomes remain present and ordered alongside all unfinished rows")
        try expect(snapshot.storedCount == 1 && snapshot.failedCount == 1 && snapshot.cancelledCount == 1 && snapshot.finishedCount == 3,
                   "Failed and cancelled terminal files are counted separately from saved files")
        try expect(snapshot.pendingCount == 3 && snapshot.pausedCount == 1 && snapshot.validatingCount == 1 && snapshot.downloadingCount == 1,
                   "Paused, validating and downloading files remain pending together")
        try expect(snapshot.batchTotalBytes == 3_100 && snapshot.batchReceivedBytes == 1_600 &&
                   abs(snapshot.batchProgress - 1_600.0 / 3_100.0) < 0.000_001,
                   "Received bytes include observed partial failed/cancelled transfers without converting them to success")
        try expect(!snapshot.isBatchPaused && snapshot.isSaving && snapshot.fileIndex == 5,
                   "A paused row does not hide concurrently validating or downloading work")
        try expect(snapshot.files[1].completedBytes == 450 && snapshot.files[2].completedBytes == 100,
                   "A terminal failure or cancellation does not fabricate a full received byte count")

        for id in ids where state.items[id]?.phase.isPending == true { _ = state.recordTerminal(fileID: id, kind: .failed) }
        let ended = LANReceptionStatus(state: state)
        try expect(ended.isFinished && !ended.allStored && ended.storedCount == 1 && ended.failedCount == 4 && ended.cancelledCount == 1,
                   "A completely terminal batch may contain failures and must not be presented as all saved")
    }

    private static func pausedAndCachedFiles() throws {
        var state = initial([100, 900])
        let ids = state.offer.files.map(\.id)
        _ = state.recordProgress(fileID: ids[0], bytes: 40)
        _ = state.recordProgress(fileID: ids[1], bytes: 300)
        _ = state.setPaused(fileID: ids[0], paused: true, revision: 1)
        _ = state.setPaused(fileID: ids[1], paused: true, revision: 1)
        let paused = LANReceptionStatus(state: state)
        try expect(paused.isBatchPaused && paused.isPaused && paused.pausedCount == 2 && paused.pendingCount == 2,
                   "A fully paused batch keeps every pending row and the paused aggregate")
        try expect(paused.batchReceivedBytes == 340 && paused.batchProgress == 0.34,
                   "Pausing preserves the actual partial byte counts")
        _ = state.setPaused(fileID: ids[0], paused: false, revision: 2)
        let resumed = LANReceptionStatus(state: state)
        try expect(!resumed.isBatchPaused && !resumed.isPaused && resumed.queuedCount == 1 && resumed.pausedCount == 1,
                   "Resuming one file exposes runnable work while the other row remains manually paused")
        try expect(resumed.batchReceivedBytes == 340 && resumed.files[1].phase == .paused,
                   "Resume neither loses existing bytes nor resumes a different paused file")

        _ = state.recordProgress(fileID: ids[0], bytes: 100)
        _ = state.setPaused(fileID: ids[0], paused: true, revision: 3)
        downloaded(ids[0], in: &state)
        let cachedPaused = LANReceptionStatus(state: state)
        try expect(cachedPaused.isBatchPaused && cachedPaused.files[0].progress == 1 && cachedPaused.storedCount == 0 && !cachedPaused.isSaving,
                   "A complete cache arriving after pause remains paused rather than saved or actively validating")
        _ = state.setPaused(fileID: ids[0], paused: false, revision: 4)
        let validating = LANReceptionStatus(state: state)
        try expect(validating.isSaving && validating.validatingCount == 1 && validating.pausedCount == 1 && !validating.isBatchPaused,
                   "Resuming a complete cache enters validation while preserving another file's pause")
        _ = state.recordTerminal(fileID: ids[0], kind: .stored)
        let tail = LANReceptionStatus(state: state)
        try expect(tail.storedCount == 1 && tail.pendingCount == 1 && tail.isBatchPaused && tail.files.map(\.id) == ids,
                   "A saved file stays in the batch while the remaining manually paused tail is visible")
    }

    private static func legacyPreviewAndBounds() throws {
        let preview = LANReceptionStatus(fileName: "Preview.flac", completedBytes: 630, totalBytes: 1_000,
            fileIndex: 2, fileCount: 12, isSaving: false)
        try expect(preview.fileName == "Preview.flac" && preview.completedBytes == 630 && preview.totalBytes == 1_000 &&
                   preview.fileIndex == 2 && preview.fileCount == 12 && !preview.isSaving && !preview.isPaused,
                   "The existing focused-file preview initializer preserves its displayed properties")
        try expect(preview.files.count == 1 && preview.storedCount == 0 && preview.failedCount == 0 && preview.cancelledCount == 0,
                   "A legacy preview cannot invent unknown batch rows or successful outcomes")
        let negative = LANReceptionFileStatus(id: "negative", fileName: "negative.mp3", completedBytes: -1, totalBytes: 100, phase: .queued)
        let oversized = LANReceptionFileStatus(id: "oversized", fileName: "oversized.mp3", completedBytes: 200, totalBytes: 100, phase: .downloading)
        let bounded = LANReceptionStatus(files: [negative, oversized])
        try expect(bounded.batchTotalBytes == 200 && bounded.batchReceivedBytes == 100 && bounded.batchProgress == 0.5 && bounded.storedCount == 0,
                   "Invalid observation bounds cannot create negative progress, over-completion or an invented save")
        let empty = LANReceptionStatus(files: [])
        try expect(empty.batchProgress == 0 && empty.batchTotalBytes == 0 && empty.batchReceivedBytes == 0 &&
                   empty.pendingCount == 0 && empty.fileCount == 0 && !empty.allStored && !empty.isBatchPaused,
                   "An empty observation has finite zero progress and no fabricated success or pause")
    }
}
