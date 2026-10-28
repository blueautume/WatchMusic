import Foundation

@main
struct LANBackgroundStateTests {
    static var assertions = 0
    static let accepted = Date(timeIntervalSince1970: 1_700_000_000)
    static let sessionA = UUID().uuidString
    static let sessionB = UUID().uuidString
    static let fileA = LANTransferFile(id: UUID().uuidString, folder: "音乐", fileName: "第一首.mp3",
                                       byteCount: 100, sha256: String(repeating: "a", count: 64))
    static let fileB = LANTransferFile(id: UUID().uuidString, folder: "音乐", fileName: "第二首.flac",
                                       byteCount: 200, sha256: String(repeating: "b", count: 64))

    static func offer(session: String = sessionA) -> LANTransferOffer {
        LANTransferOffer(sessionID: session, token: String(repeating: "c", count: 64),
                         baseURLs: [URL(string: "http://192.168.1.5:49152")!],
                         expiresAt: accepted.addingTimeInterval(900), files: [fileA, fileB])
    }

    static func initial(session: String = sessionA) -> LANBackgroundTransferState {
        LANBackgroundTransferState(offer: offer(session: session), acceptedAt: accepted)
    }

    static func receipt(session: String = sessionA, file: LANTransferFile = fileA,
                        kind: LANTransferEvent.Kind = .stored, bytes: Int64? = nil) -> LANTransferEvent {
        LANTransferEvent(sessionID: session, fileID: file.id, kind: kind,
                         completedBytes: bytes ?? file.byteCount, totalBytes: file.byteCount, message: nil)
    }

    static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        assertions += 1
        guard try value() else { throw NSError(domain: "LANBackgroundTests", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: label]) }
    }

    static func rejected(_ state: LANBackgroundTransferState) -> Bool {
        do { try state.validateForRestoration(allowLoopback: false); return false } catch { return true }
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    static func main() throws {
        var state = initial()
        try state.validateForRestoration(allowLoopback: false)
        try expect(state.pendingFileIDs == Set([fileA.id, fileB.id]), "every selected file survives as pending intent")
        try expect(!state.isFinished, "queued batch is unfinished")
        try expect(!state.recordTerminal(fileID: fileA.id, kind: .stored), "cannot claim stored before validation")
        try expect(!state.recordProgress(fileID: fileA.id, bytes: -1), "negative progress rejected")
        try expect(state.recordProgress(fileID: fileA.id, bytes: 40), "normal download progress recorded")
        try expect(!state.recordProgress(fileID: fileA.id, bytes: 39), "out of order progress cannot regress")
        try expect(!state.recordProgress(fileID: fileA.id, bytes: 101), "oversized progress rejected")
        try expect(!state.recordProgress(fileID: UUID().uuidString, bytes: 1), "unknown file cannot enter a batch")
        state.items[fileA.id]?.taskIdentifier = 42
        let staging = UUID().uuidString + ".download"
        try expect(state.recordDownloaded(fileID: fileA.id, stagingName: staging), "completed download enters durable validation phase")
        try expect(state.items[fileA.id]?.taskIdentifier == nil, "validating data no longer needs a daemon task")
        try expect(state.items[fileA.id]?.receivedBytes == fileA.byteCount, "completed byte count recovered")
        try expect(!state.recordDownloaded(fileID: fileA.id, stagingName: UUID().uuidString + ".download"), "duplicate completion cannot replace validation cache")
        try expect(!state.recordProgress(fileID: fileA.id, bytes: 100), "download progress cannot rewrite validation phase")
        state = try roundTrip(state)
        try state.validateForRestoration(allowLoopback: false)
        try expect(state.items[fileA.id]?.stagingName == staging, "cached validation work survives process recreation")
        try expect(state.pendingFileIDs.contains(fileA.id), "missing native task does not lose cached validation work")
        try expect(state.canStartRequest(at: accepted.addingTimeInterval(899)), "request allowed before expiry")
        try expect(!state.canStartRequest(at: accepted.addingTimeInterval(900)), "new request forbidden at expiry")
        try expect(!state.canStartRequest(at: accepted.addingTimeInterval(3_600)), "new request forbidden after expiry")
        // The accepted time is deliberately in the past. Expired network offers
        // still restore a file that URLSession has already delivered.
        try expect(!rejected(state), "expiry does not invalidate already downloaded data")

        var malformed = state
        malformed.items[fileA.id]?.stagingName = nil
        try expect(rejected(malformed), "validation without cached path is rejected")
        malformed = state
        malformed.items[fileA.id]?.stagingName = "../" + staging
        try expect(rejected(malformed), "cache path traversal is rejected")
        malformed = state
        malformed.items[fileA.id]?.phase = .downloading
        try expect(rejected(malformed), "network task cannot own a validation cache path")
        malformed = state
        malformed.items[fileA.id]?.taskIdentifier = 42
        try expect(rejected(malformed), "validation cache cannot retain a native network task identity")
        malformed = state
        malformed.items[fileB.id]?.receivedBytes = 201
        try expect(rejected(malformed), "restored byte count is bounded by manifest")
        malformed = state
        malformed.items[fileB.id]?.addressIndex = 1
        try expect(rejected(malformed), "restored endpoint index must be authorized")
        malformed = state
        malformed.items[UUID().uuidString] = LANBackgroundTransferState.Item()
        try expect(rejected(malformed), "restored file identities must match the manifest")

        try expect(state.recordTerminal(fileID: fileA.id, kind: .stored), "verified cache can commit stored outcome")
        try expect(!state.recordTerminal(fileID: fileA.id, kind: .cancelled), "late cancellation cannot rewrite stored outcome")
        try expect(state.items[fileA.id]?.stagingName == nil, "terminal state no longer references cache")
        try expect(state.pendingFileIDs == Set([fileB.id]), "only unfinished paths need reservations")
        try expect(!state.recordTerminal(fileID: fileB.id, kind: .progress), "progress is not a terminal outcome")
        try expect(state.recordTerminal(fileID: fileB.id, kind: .cancelled), "queued task can be cancelled")
        try expect(state.isFinished, "stored and cancelled files complete the batch")

        let description = LANBackgroundTransferState.taskDescription(sessionID: sessionA, fileID: fileA.id)
        let identity = LANBackgroundTransferState.taskIdentity(description)
        try expect(identity?.sessionID == sessionA && identity?.fileID == fileA.id, "daemon task binds session and file")
        for bad in [nil, "", sessionA, sessionA + "|bad", "bad|" + fileA.id, description + "|extra"] as [String?] {
            try expect(LANBackgroundTransferState.taskIdentity(bad) == nil, "malformed native task identity rejected")
        }

        // Simulate death after the terminal outbox fsync but before manifest
        // fsync: the stale manifest must never restart cancelled/stored files.
        var staleManifest = initial()
        staleManifest.items[fileA.id]?.taskIdentifier = 73
        var outbox = LANBackgroundReceiptOutbox()
        outbox.insert(receipt(kind: .cancelled, bytes: 20))
        outbox.insert(receipt(file: fileB))
        outbox = try roundTrip(outbox)
        for event in outbox.events { staleManifest.applyTerminalReceipt(event) }
        try expect(staleManifest.isFinished, "durable receipt closes crash-window pending intents")
        try expect(staleManifest.items[fileA.id]?.phase == .cancelled, "cancelled task cannot restart after crash")
        try expect(staleManifest.items[fileB.id]?.phase == .stored, "durable stored receipt avoids duplicate storage")
        try expect(staleManifest.items[fileA.id]?.taskIdentifier == nil, "terminal receipt detaches obsolete daemon identity")
        var newBatch = initial(session: sessionB)
        try expect(!newBatch.applyTerminalReceipt(receipt()), "old session receipt cannot finish a new batch sharing file ID")
        try expect(!newBatch.applyTerminalReceipt(receipt(session: sessionB, bytes: 99)), "partial stored receipt cannot finish a file")
        outbox.insert(receipt(session: sessionB))
        outbox.acknowledge(sessionID: sessionA, fileID: fileA.id)
        try expect(!outbox.contains(sessionID: sessionA, fileID: fileA.id), "acknowledgement removes exact historical receipt")
        try expect(outbox.contains(sessionID: sessionB, fileID: fileA.id), "old acknowledgement preserves new session receipt")
        try expect(outbox.contains(sessionID: sessionA, fileID: fileB.id), "old acknowledgement preserves another old file")
        try expect(newBatch.pendingFileIDs.count == 2, "outbox acknowledgement does not clear current transfer")
        outbox.insert(receipt(session: sessionB, file: fileB, kind: .progress))
        try expect(!outbox.contains(sessionID: sessionB, fileID: fileB.id), "progress is never replayed as a terminal receipt")
        let invalid = [sessionA + "/" + fileA.id: receipt(bytes: 99)]
        let filtered = try JSONDecoder().decode(LANBackgroundReceiptOutbox.self, from: JSONEncoder().encode(invalid))
        try expect(filtered.count == 0, "malformed persisted stored receipt is ignored")

        var barrier = LANBackgroundDeliveryBarrier()
        try expect(!barrier.canComplete, "native completion cannot run before event drain")
        try expect(barrier.beginValidation("A"), "first validation registered")
        try expect(!barrier.beginValidation("A"), "same cache cannot validate twice")
        try expect(barrier.beginValidation("B"), "second validation registered")
        barrier.didFinishEvents()
        try expect(!barrier.canComplete, "event drain waits for file saves started by this delivery")
        barrier.finishValidation("A")
        try expect(!barrier.canComplete, "one saved file does not complete another pending save")
        barrier.finishValidation("B")
        try expect(barrier.canComplete, "drain and all saves permit native completion")
        try expect(newBatch.pendingFileIDs.count == 2 && barrier.canComplete, "other network downloads do not block completed delivery")
        try expect(barrier.canComplete, "a late handler for already drained delivery completes immediately")
        barrier.beginDelivery()
        try expect(!barrier.canComplete, "previous drain cannot complete a fresh delivery")
        barrier.didFinishEvents()
        try expect(barrier.canComplete, "fresh empty delivery can complete after drain")
        barrier.beginReconciliation()
        try expect(!barrier.canComplete, "drain waits for asynchronous daemon task reconciliation")
        barrier.finishReconciliation()
        try expect(barrier.canComplete, "reconciled missing tasks permit native completion")

        // Pause is durable transport state, not a terminal success/failure.
        var pauseOffer = offer()
        pauseOffer.pausedFileIDs = [fileA.id]
        var paused = LANBackgroundTransferState(offer: pauseOffer, acceptedAt: accepted)
        try expect(paused.items[fileA.id]?.phase == .paused, "preparation pause starts with a suspended intent")
        try expect(paused.pendingFileIDs.contains(fileA.id), "paused paths remain reserved and unfinished")
        paused.items[fileA.id]?.taskIdentifier = 81
        try expect(paused.recordProgress(fileID: fileA.id, bytes: 35), "in-flight bytes are counted after a pause request")
        try expect(paused.items[fileA.id]?.phase == .paused, "late bytes cannot silently resume a paused task")
        try expect(paused.setPaused(fileID: fileA.id, paused: false, revision: 1), "resume releases paused intent to the serial queue")
        try expect(paused.items[fileA.id]?.phase == .queued, "resuming does not claim the network lane before scheduling")
        try expect(paused.items[fileA.id]?.receivedBytes == 35, "resume preserves native partial progress")
        try expect(paused.setPaused(fileID: fileA.id, paused: true, revision: 2), "a newer pause is accepted")
        try expect(!paused.setPaused(fileID: fileA.id, paused: true, revision: 2), "duplicate controls cannot add another native suspension")
        try expect(!paused.setPaused(fileID: fileA.id, paused: false, revision: 1), "delayed resume cannot overtake a newer pause")
        let pausedCache = UUID().uuidString + ".download"
        try expect(paused.recordDownloaded(fileID: fileA.id, stagingName: pausedCache), "completion racing pause is moved into durable cache")
        try expect(paused.items[fileA.id]?.phase == .paused, "complete bytes remain paused until explicit resume")
        try expect(!paused.recordTerminal(fileID: fileA.id, kind: .stored), "paused cached data cannot publish a saved file")
        paused = try roundTrip(paused)
        try paused.validateForRestoration(allowLoopback: false)
        try expect(paused.items[fileA.id]?.stagingName == pausedCache && paused.items[fileA.id]?.controlRevision == 2,
                   "paused cache and control ordering survive process restart")
        try expect(paused.setPaused(fileID: fileA.id, paused: false, revision: 3), "explicit start releases cached bytes for validation")
        try expect(paused.items[fileA.id]?.phase == .validating && paused.items[fileA.id]?.taskIdentifier == nil,
                   "cached resume validates locally instead of issuing another download")
        try expect(!paused.setPaused(fileID: fileA.id, paused: true, revision: 4), "saving already in flight is not falsely reported paused")
        try expect(paused.recordTerminal(fileID: fileA.id, kind: .stored), "released cache may finish storage")
        try expect(!paused.setPaused(fileID: fileA.id, paused: true, revision: 5), "late pause cannot resurrect a stored task")
        var pauseOutbox = LANBackgroundReceiptOutbox()
        pauseOutbox.insert(receipt(kind: .paused, bytes: 35))
        pauseOutbox.insert(receipt(kind: .resumed, bytes: 35))
        try expect(pauseOutbox.count == 0, "pause/resume states are never persisted as terminal receipts")
        var cancellable = initial()
        try expect(cancellable.setPaused(fileID: fileA.id, paused: true, revision: 1), "queued task can pause before download")
        try expect(cancellable.recordTerminal(fileID: fileA.id, kind: .cancelled), "clear can cancel a paused task")
        try expect(!cancellable.setPaused(fileID: fileA.id, paused: false, revision: 2), "late start cannot resurrect a cleared task")

        // A single deterministic lane includes both the network and final save.
        var serial = initial()
        try expect(serial.nextRunnableFileID() == fileA.id, "untouched batch starts in manifest order")
        serial.items[fileA.id]?.phase = .downloading
        try expect(serial.nextRunnableFileID(keeping: fileA.id) == fileA.id, "download keeps the lane while the next file is queued")
        try expect(serial.recordDownloaded(fileID: fileA.id, stagingName: UUID().uuidString + ".download"), "serial first download reaches save phase")
        try expect(serial.nextRunnableFileID(keeping: fileA.id) == fileA.id, "next download waits until current file finishes saving")
        try expect(serial.recordTerminal(fileID: fileA.id, kind: .stored), "serial first file saves")
        try expect(serial.nextRunnableFileID(keeping: fileA.id) == fileB.id, "saved file releases the lane to the next manifest item")
        try expect(serial.recordTerminal(fileID: fileB.id, kind: .failed), "failed final file closes its work")
        try expect(serial.nextRunnableFileID() == nil, "stored and failed items never restart")

        serial = initial()
        try expect(serial.recordTerminal(fileID: fileA.id, kind: .failed), "queued first file may fail")
        try expect(serial.nextRunnableFileID() == fileB.id, "failure advances to the next song")
        serial = initial()
        try expect(serial.recordTerminal(fileID: fileA.id, kind: .cancelled), "queued first file may cancel")
        try expect(serial.nextRunnableFileID() == fileB.id, "cancellation advances to the next song")

        serial = initial()
        try expect(serial.setPaused(fileID: fileA.id, paused: true, revision: 1), "first item can be held before its turn")
        try expect(serial.nextRunnableFileID(keeping: fileA.id) == fileB.id, "paused item releases the lane without blocking eligible songs")
        serial.items[fileB.id]?.phase = .downloading
        try expect(serial.setPaused(fileID: fileA.id, paused: false, revision: 2), "earlier held song can rejoin the queue")
        try expect(serial.nextRunnableFileID(keeping: fileB.id) == fileB.id, "resuming an earlier song does not preempt the active download")
        try expect(serial.nextRunnableFileID() == fileB.id, "existing download outranks a resumed queued song after restoration")
        try expect(serial.setPaused(fileID: fileB.id, paused: true, revision: 1), "active download can release the lane by pausing")
        try expect(serial.nextRunnableFileID(keeping: fileB.id) == fileA.id, "a paused active identity cannot retain the lane")
        try expect(serial.setPaused(fileID: fileA.id, paused: true, revision: 3), "last eligible song can pause")
        try expect(serial.nextRunnableFileID() == nil && !serial.isFinished, "all paused means no runnable work, not a finished batch")

        // Upgrade from an older concurrent receiver deterministically chooses
        // one active intent, independently of dictionary insertion order.
        serial = initial()
        serial.items[fileB.id]?.phase = .downloading
        serial.items[fileA.id]?.phase = .downloading
        try expect(serial.nextRunnableFileID() == fileA.id, "legacy parallel downloads choose the first manifest item")
        try expect(serial.nextRunnableFileID(keeping: fileB.id) == fileB.id, "an explicitly retained active download remains stable")
        try expect(serial.recordDownloaded(fileID: fileB.id, stagingName: UUID().uuidString + ".download"), "legacy later file can already have complete cached data")
        try expect(serial.nextRunnableFileID() == fileB.id, "restore drains complete cached validation before starting another download")
        try expect(serial.nextRunnableFileID(keeping: fileA.id) == fileA.id, "newly released cached data does not preempt an existing lane")
        try expect(serial.recordDownloaded(fileID: fileA.id, stagingName: UUID().uuidString + ".download"), "legacy first file can also await save")
        try expect(serial.nextRunnableFileID() == fileA.id, "multiple restored caches save in manifest order")
        try expect(serial.nextRunnableFileID(keeping: UUID().uuidString) == fileA.id, "unknown active identity cannot steal or block the lane")
        var chunks = initial()
        chunks.items[fileA.id]?.phase = .downloading
        chunks.items[fileA.id]?.taskIdentifier = 90
        chunks.items[fileA.id]?.committedBytes = 0
        chunks.items[fileA.id]?.requestedOffset = 0
        chunks.items[fileA.id]?.requestedLength = 40
        try expect(!rejected(chunks), "bounded HTTP request metadata restores")
        try expect(chunks.recordProgress(fileID: fileA.id, bytes: 40), "current range reports cumulative bytes")
        try expect(chunks.recordChunk(fileID: fileA.id, committedBytes: 40), "complete range commits a resumable boundary")
        try expect(chunks.items[fileA.id]?.taskIdentifier == nil && chunks.items[fileA.id]?.requestedLength == nil,
                   "committing a range detaches the completed native request")
        try expect(chunks.nextRunnableFileID(keeping: fileA.id) == fileA.id, "next chunk retains the song's serial lane")
        try expect(!chunks.recordChunk(fileID: fileA.id, committedBytes: 40), "a duplicate range cannot advance the checkpoint")
        try expect(!chunks.recordChunk(fileID: fileA.id, committedBytes: 100), "full content must enter validation instead of a partial phase")
        chunks.items[fileA.id]?.requestedOffset = 40
        chunks.items[fileA.id]?.requestedLength = 60
        chunks = try roundTrip(chunks)
        try expect(!rejected(chunks), "committed prefix and remaining request survive process restoration")
        malformed = chunks
        malformed.items[fileA.id]?.requestedOffset = 39
        try expect(rejected(malformed), "request cannot overlap committed bytes")
        malformed = chunks
        malformed.items[fileA.id]?.requestedLength = 61
        try expect(rejected(malformed), "request cannot extend past full content")
        malformed = chunks
        malformed.items[fileA.id]?.requestedLength = nil
        try expect(rejected(malformed), "incomplete request metadata is rejected")
        malformed = chunks
        malformed.items[fileA.id]?.receivedBytes = 39
        try expect(rejected(malformed), "received progress cannot precede committed bytes")
        try expect(chunks.recordDownloaded(fileID: fileA.id, stagingName: UUID().uuidString + ".download"), "last range enters complete validation")
        try expect(chunks.items[fileA.id]?.committedBytes == nil && chunks.items[fileA.id]?.requestedOffset == nil,
                   "full validation detaches resumable prefix bookkeeping")
        print("PASS: \(assertions) LAN background state assertions")
    }
}
