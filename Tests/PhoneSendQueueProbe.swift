import Darwin
import Foundation

/// Real PhoneLibrary/file preparation with an explicit in-memory transport peer.
/// No WatchConnectivity pairing, audio playback, or persisted transfer writes.
@main
struct PhoneSendQueueProbe {
    @MainActor private static var assertions = 0

    @MainActor static func main() async {
        do {
            try await run()
            print("PASS: \(assertions) phone append/dedup queue assertions")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("PHONE_SEND_QUEUE_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeFailure.failed(message) }
        assertions += 1
    }

    @MainActor private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(condition(), "Timed out: " + message)
    }

    @MainActor private static func send(_ tracks: [PhoneTrack], using library: PhoneLibrary) async -> Set<String> {
        await withCheckedContinuation { continuation in
            library.send(tracks) { continuation.resume(returning: $0) }
        }
    }

    @MainActor private static func ready(_ count: Int, library: PhoneLibrary, peer: QueuePeer) async throws {
        try await wait("offer \(count); \(library.errorMessage ?? "no model error")") {
            peer.offers.count == count && !library.isPreparingLAN && !library.isAwaitingLANAcceptance
        }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count > 1, CommandLine.arguments.contains("-preview-transfers-in-progress") else {
            throw ProbeFailure.failed("An audio fixture and explicit isolated preview mode are required")
        }
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard documents.path.contains("/CoreSimulator/Devices/") else { throw ProbeFailure.failed("Simulator only") }
        let music = documents.appendingPathComponent("Music", isDirectory: true)
        let index = documents.appendingPathComponent("transfers.json")
        let indexBefore = try? Data(contentsOf: index)
        let musicExisted = manager.fileExists(atPath: music.path)
        let prefix = "SendQueueProbe-" + UUID().uuidString
        var directories = ["A", "B"].map { music.appendingPathComponent(prefix + "-" + $0, isDirectory: true) }
        var models: [PhoneLibrary] = []
        defer {
            models.forEach { $0.clearAllTasks() }
            directories.forEach { try? manager.removeItem(at: $0) }
            if !musicExisted, (try? manager.contentsOfDirectory(atPath: music.path).isEmpty) == true { try? manager.removeItem(at: music) }
            if (try? Data(contentsOf: index)) != indexBefore {
                if let bytes = indexBefore { try? bytes.write(to: index, options: .atomic) }
                else { try? manager.removeItem(at: index) }
            }
        }
        for directory in directories { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        func track(_ directory: URL, _ name: String) throws -> PhoneTrack {
            let url = directory.appendingPathComponent(name)
            try manager.copyItem(at: fixture, to: url)
            return PhoneTrack(folder: directory.lastPathComponent, fileName: name, url: url,
                              bytes: Int64((try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0))
        }
        let a1 = try track(directories[0], "one.mp3")
        let a2 = try track(directories[0], "two.mp3")
        let b1 = try track(directories[1], "one.mp3")
        let b2 = try track(directories[1], "two.mp3")
        func model(_ peer: QueuePeer) -> PhoneLibrary {
            let library = PhoneLibrary()
            library.configureTransferQueueProbe { try await peer.request($0) }
            models.append(library)
            return library
        }

        // Existing watch content, rather than local history, is authoritative.
        let storedPeer = QueuePeer()
        try storedPeer.remember(a1)
        let stored = model(storedPeer)
        try check(await send([a1], using: stored) == [a1.id], "Already stored songs complete selection handling")
        try check(stored.transfers.count == 1 && stored.storedTransfers.count == 1 && stored.activeTransfers.isEmpty,
                  "A watch match creates no unfinished task")
        try check(storedPeer.offers.isEmpty, "A watch match never starts a transfer offer")
        let storedID = stored.transfers[0].id
        try check(await send([a1, a1], using: stored) == [a1.id], "All-duplicate selection still reports every unique handled track")
        try check(stored.transfers.count == 1 && stored.transfers[0].id == storedID, "Repeated stored songs do not duplicate successful history")
        stored.clearCompletedTransfers()
        try check(stored.transfers.isEmpty, "Successful history can be cleared independently")
        _ = await send([a1], using: stored)
        try check(storedPeer.offers.isEmpty && stored.storedTransfers.count == 1, "Clearing phone history does not retransmit existing watch content")
        storedPeer.saved.removeAll()
        _ = await send([a1], using: stored)
        try await ready(1, library: stored, peer: storedPeer)
        try check(stored.activeTransfers.count == 1, "A song deleted on the watch becomes eligible again")
        storedPeer.finish(storedPeer.offers[0].files[0], in: storedPeer.offers[0], on: stored)

        // Append a different folder while the first batch still owns the lane.
        let appendPeer = QueuePeer()
        let append = model(appendPeer)
        try check(await send([a1, a2], using: append) == [a1.id, a2.id], "First batch accepts both songs")
        try await ready(1, library: append, peer: appendPeer)
        let first = appendPeer.offers[0]
        appendPeer.finish(first.files[0], in: first, on: append)
        try check(append.isLANActive && appendPeer.offers.count == 1, "One saved song does not finish an unfinished batch")
        try check(await send([b1, b2], using: append) == [b1.id, b2.id], "A second folder is accepted during the current batch")
        try check(appendPeer.offers.count == 1 && appendPeer.stopCount == 0, "Appending neither replaces nor stops the current offer")
        let waiting = append.transfers.filter { $0.folder == b1.folder && $0.state == .queued }
        try check(waiting.count == 2 && waiting.allSatisfy { $0.lanSessionID == nil && !append.isCurrentLANTransfer($0.id) },
                  "Appended songs remain visibly waiting for their own batch")
        let beforeDuplicate = append.transfers.count
        let inventoryBefore = appendPeer.inventoryCount
        try check(await send([b1], using: append) == [b1.id], "Pending duplicates complete selection handling")
        try check(append.transfers.count == beforeDuplicate && appendPeer.inventoryCount == inventoryBefore,
                  "Pending duplicates create neither another record nor an inventory request")
        let queuedB1 = append.latestTransfer(for: b1)!
        let queuedB2 = append.latestTransfer(for: b2)!
        append.pauseTransfers(ids: [queuedB1.id])
        try check(append.latestTransfer(for: b1)?.state == .paused, "A waiting song can be paused locally")
        append.resumeTransfers(ids: [queuedB1.id])
        try check(append.latestTransfer(for: b1)?.state == .queued && appendPeer.offers.count == 1, "Waiting resume does not preempt the active offer")
        append.clearTransfers(ids: [queuedB2.id])
        try check(!append.transfers.contains { $0.id == queuedB2.id } && manager.fileExists(atPath: b2.url.path),
                  "Clearing waiting work keeps its music file")
        appendPeer.finish(first.files[1], in: first, on: append)
        try await ready(2, library: append, peer: appendPeer)
        let second = appendPeer.offers[1]
        try check(second.sessionID != first.sessionID && second.files.map(\.folder) == [b1.folder] && second.files.map(\.fileName) == [b1.fileName],
                  "Only after the entire first batch is saved does the next folder start, excluding cleared tasks")
        appendPeer.finish(second.files[0], in: second, on: append)
        try check(!append.isLANActive && append.activeTransfers.isEmpty, "Queue finishes after its last appended song")

        // A large selection is one queue even when the wire offer has a
        // per-batch item limit. The peer rejects overlapping offers.
        let bulkTracks = try (0..<111).map { try track(directories[0], String(format: "bulk-%03d.mp3", $0)) }
        let bulkPeer = QueuePeer()
        let bulk = model(bulkPeer)
        try check(await send(bulkTracks, using: bulk) == Set(bulkTracks.map(\.id)), "A selection larger than one manifest is fully accepted")
        try await ready(1, library: bulk, peer: bulkPeer)
        let bulkFirst = bulkPeer.offers[0]
        try check(bulkFirst.files.count == 100 && bulk.pendingCount == 111, "First offer contains 100 songs while all 111 remain in the queue")
        for file in bulkFirst.files.dropLast() { bulkPeer.finish(file, in: bulkFirst, on: bulk) }
        try check(bulkPeer.offers.count == 1 && bulk.pendingCount == 12, "The final song of the first manifest still blocks the remaining offer")
        bulkPeer.finish(bulkFirst.files.last!, in: bulkFirst, on: bulk)
        try await ready(2, library: bulk, peer: bulkPeer)
        let bulkSecond = bulkPeer.offers[1]
        try check(bulkSecond.files.count == 11 && bulkPeer.stopCount == 0, "The remaining eleven start in a fresh offer without stopping live work")
        try check((bulkFirst.files + bulkSecond.files).map(\.fileName) == bulkTracks.map(\.fileName), "Automatic batches preserve selection order exactly once")
        for file in bulkSecond.files { bulkPeer.finish(file, in: bulkSecond, on: bulk) }
        try check(!bulk.isLANActive && bulk.pendingCount == 0 && bulk.storedTransfers.count == 111, "Every large-selection task reaches a stored terminal state")
        try check(bulkTracks.allSatisfy { manager.fileExists(atPath: $0.url.path) }, "Batch splitting retains all 111 source files")

        // Long but supported destination names must split before the wire
        // payload limit, even when there are fewer than 100 selected songs.
        let longFolderName = prefix + String(repeating: "F", count: 180 - prefix.utf8.count)
        let longDirectory = music.appendingPathComponent(longFolderName, isDirectory: true)
        directories.append(longDirectory)
        try manager.createDirectory(at: longDirectory, withIntermediateDirectories: false)
        let longTracks = try (0..<90).map {
            try track(longDirectory, String(repeating: "n", count: 165) + String(format: "%03d.mp3", $0))
        }
        let longPeer = QueuePeer()
        let longQueue = model(longPeer)
        _ = await send(longTracks, using: longQueue)
        var longBatch = 0
        while longQueue.pendingCount > 0 {
            try await ready(longBatch + 1, library: longQueue, peer: longPeer)
            let offer = longPeer.offers[longBatch]
            try check(offer.files.count <= 100 && (try JSONEncoder().encode(offer).count) <= 55_000,
                      "Every actual encoded manifest stays within the wire size limit")
            for file in offer.files { longPeer.finish(file, in: offer, on: longQueue) }
            longBatch += 1
        }
        try check(longPeer.offers.count > 1 && longPeer.offers[0].files.count < 100,
                  "Manifest byte budget splits a long-name selection before the count limit")
        try check(longPeer.offers.flatMap(\.files).map(\.fileName) == longTracks.map(\.fileName) && longQueue.storedTransfers.count == 90,
                  "Size-budget splitting preserves every long-name song in queue order")

        // Global pause is an intent for future submissions as well as current
        // remote work; clearing tasks resets that intent.
        let pausedPeer = QueuePeer()
        let pausedQueue = model(pausedPeer)
        _ = await send([a1], using: pausedQueue)
        try await ready(1, library: pausedQueue, peer: pausedPeer)
        let pausedFirst = pausedPeer.offers[0]
        pausedQueue.pauseTransfers()
        try await wait("global pause acknowledgement") {
            !pausedQueue.isUpdatingTransferControls && pausedQueue.latestTransfer(for: a1)?.state == .paused
        }
        try check(await send([b1], using: pausedQueue) == [b1.id], "Global pause still accepts another folder")
        try check(pausedQueue.latestTransfer(for: b1)?.state == .paused && pausedPeer.offers.count == 1 && pausedQueue.shouldStartTransfers(),
                  "A newly appended song inherits global pause and does not start another offer")
        pausedQueue.resumeTransfers()
        try await wait("global resume acknowledgement") {
            !pausedQueue.isUpdatingTransferControls && pausedQueue.latestTransfer(for: a1)?.state == .queued
        }
        try check(pausedQueue.latestTransfer(for: b1)?.state == .queued && pausedPeer.offers.count == 1,
                  "Global resume releases future songs while preserving the current offer")
        pausedPeer.finish(pausedFirst.files[0], in: pausedFirst, on: pausedQueue)
        try await ready(2, library: pausedQueue, peer: pausedPeer)
        let pausedSecond = pausedPeer.offers[1]
        pausedPeer.finish(pausedSecond.files[0], in: pausedSecond, on: pausedQueue)
        pausedQueue.pauseTransfers()
        _ = await send([b2], using: pausedQueue)
        try check(pausedQueue.latestTransfer(for: b2)?.state == .paused && pausedPeer.offers.count == 2,
                  "Global pause also applies when the queue is currently empty")
        pausedQueue.clearAllTasks()
        _ = await send([b2], using: pausedQueue)
        try await ready(3, library: pausedQueue, peer: pausedPeer)
        let afterClear = pausedPeer.offers[2]
        try check(afterClear.files.count == 1 && afterClear.pausedFileIDs?.isEmpty != false,
                  "Clear-all resets global pause for the next selection")
        pausedPeer.finish(afterClear.files[0], in: afterClear, on: pausedQueue)
        try check(manager.fileExists(atPath: b2.url.path), "Global pause and clear preserve source music")

        // A paused active batch needs Start even if a later folder is queued;
        // selecting just that future folder still offers its own Pause action.
        let priorityPeer = QueuePeer()
        let priorityQueue = model(priorityPeer)
        _ = await send([a1], using: priorityQueue)
        try await ready(1, library: priorityQueue, peer: priorityPeer)
        _ = await send([b1], using: priorityQueue)
        let priorityFirst = priorityPeer.offers[0]
        priorityQueue.pauseTransfers(ids: [priorityFirst.files[0].id])
        try await wait("selected current pause") {
            !priorityQueue.isUpdatingTransferControls && priorityQueue.latestTransfer(for: a1)?.state == .paused
        }
        let futureID = priorityQueue.latestTransfer(for: b1)!.id
        try check(priorityQueue.latestTransfer(for: b1)?.state == .queued && priorityQueue.shouldStartTransfers() &&
                  !priorityQueue.shouldStartTransfers(ids: [futureID]), "Global Start prioritizes the paused active batch while future selection keeps its Pause action")
        priorityQueue.toggleTransfers()
        try await wait("global Start resumes the current batch") {
            !priorityQueue.isUpdatingTransferControls && priorityQueue.latestTransfer(for: a1)?.state == .queued
        }
        priorityPeer.finish(priorityFirst.files[0], in: priorityFirst, on: priorityQueue)
        try await ready(2, library: priorityQueue, peer: priorityPeer)
        let prioritySecond = priorityPeer.offers[1]
        priorityPeer.finish(prioritySecond.files[0], in: prioritySecond, on: priorityQueue)

        // Failed work can be retried behind a different active song.
        let retryPeer = QueuePeer()
        let retry = model(retryPeer)
        _ = await send([a1, a2], using: retry)
        try await ready(1, library: retry, peer: retryPeer)
        let retryFirst = retryPeer.offers[0]
        retryPeer.finish(retryFirst.files[0], in: retryFirst, on: retry, kind: .failed)
        let failed = retry.latestTransfer(for: a1)!
        try check(failed.state == .failed, "A failed current file remains retryable")
        retry.retry(failed)
        try await wait("active-batch retry enters the waiting queue") {
            retry.transfers.contains { $0.folder == a1.folder && $0.fileName == a1.fileName && $0.state == .queued && $0.id != failed.id }
        }
        try check(retryPeer.offers.count == 1 && retryPeer.stopCount == 0, "Retry also queues without stopping the active batch")
        retryPeer.finish(retryFirst.files[1], in: retryFirst, on: retry)
        try await ready(2, library: retry, peer: retryPeer)
        let retried = retryPeer.offers[1]
        try check(retried.files.count == 1 && retried.files[0].fileName == a1.fileName, "Retry starts alone after the previous batch finishes")
        retryPeer.finish(retried.files[0], in: retried, on: retry)

        // A second check at dispatch avoids resending content that appeared
        // while this batch was waiting behind another folder.
        let latePeer = QueuePeer()
        let late = model(latePeer)
        _ = await send([a1], using: late)
        try await ready(1, library: late, peer: latePeer)
        _ = await send([b1], using: late)
        try latePeer.remember(b1)
        let lateFirst = latePeer.offers[0]
        latePeer.finish(lateFirst.files[0], in: lateFirst, on: late)
        try await wait("dispatch-time inventory match finishes waiting work") { !late.isLANActive && late.activeTransfers.isEmpty }
        try check(latePeer.offers.count == 1 && late.latestTransfer(for: b1)?.state == .stored,
                  "Dispatch-time duplicates finish without another offer")

        // Source version and content are both real, including same-size writes.
        let mutationPeer = QueuePeer()
        try mutationPeer.remember(a1)
        let mutation = model(mutationPeer)
        _ = await send([a1], using: mutation)
        try check(mutation.isFullyTransferred(a1), "Unchanged stored source has a valid transferred indicator")
        let before = try TransferSourceVersion.read(a1.url)
        let bytes = try Data(contentsOf: a1.url)
        let output = try FileHandle(forUpdating: a1.url)
        try output.seek(toOffset: UInt64(bytes.count - 1))
        try output.write(contentsOf: Data([bytes.last! ^ 0xff]))
        try output.close()
        let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(before.modificationSeconds), tv_nsec: Int(before.modificationNanoseconds))]
        let restored = a1.url.withUnsafeFileSystemRepresentation { path in
            times.withUnsafeBufferPointer { Darwin.utimensat(AT_FDCWD, path!, $0.baseAddress, 0) }
        }
        try check(restored == 0, "Test restores the exact original mtime")
        let after = try TransferSourceVersion.read(a1.url)
        try check(after.byteCount == before.byteCount && after.modificationSeconds == before.modificationSeconds &&
                  after.modificationNanoseconds == before.modificationNanoseconds, "Changed fixture retains its size and mtime")
        try check(!mutation.isFullyTransferred(a1), "Same-size replacement invalidates the transferred indicator")
        _ = await send([a1], using: mutation)
        try await ready(1, library: mutation, peer: mutationPeer)
        let changed = mutationPeer.offers[0]
        try check(changed.files[0].sha256 != mutationPeer.saved[LANInventoryWire.pathKey(folder: a1.folder, fileName: a1.fileName)]?.hash,
                  "Changed content is sent even with the same destination, size and mtime")
        mutationPeer.finish(changed.files[0], in: changed, on: mutation)

        // Cancellation generations reject a reply that arrives after clear or
        // background, while a newer submission remains able to make progress.
        for background in [false, true] {
            let peer = QueuePeer()
            peer.holdNextInventory = true
            let library = model(peer)
            var completionCount = 0
            var completedIDs: Set<String>?
            library.send([a2]) { completionCount += 1; completedIDs = $0 }
            try await wait("held inventory request") { peer.hasHeldInventory }
            if background { library.sceneDidEnterBackground() } else { library.clearAllTasks() }
            try check(completionCount == 1 && completedIDs == [], "\(background ? "Background" : "Clear") finishes pending selection exactly once")
            if background { library.sceneDidBecomeActive() }
            _ = await send([b2], using: library)
            try await ready(1, library: library, peer: peer)
            peer.releaseInventory()
            try await Task.sleep(nanoseconds: 80_000_000)
            try check(completionCount == 1 && !library.transfers.contains { $0.folder == a2.folder && $0.fileName == a2.fileName },
                      "Late inventory cannot recreate cleared submission or complete it twice")
            try check(peer.offers.count == 1 && peer.offers[0].files[0].folder == b2.folder,
                      "A new submission survives an older cancelled inventory response")
            let offer = peer.offers[0]
            peer.finish(offer.files[0], in: offer, on: library)
        }

        try check((try? Data(contentsOf: index)) == indexBefore, "Isolated send operations leave the real transfer index untouched")
        for item in [a1, a2, b1, b2] { try check(manager.fileExists(atPath: item.url.path), "Queue control preserves every source file") }
    }

    private enum ProbeFailure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}

@MainActor
private final class QueuePeer {
    struct Fingerprint { let bytes: Int64; let hash: String }
    var saved: [String: Fingerprint] = [:]
    var offers: [LANTransferOffer] = []
    var inventoryCount = 0
    var stopCount = 0
    var holdNextInventory = false
    var hasHeldInventory: Bool { heldInventory != nil }
    private var pending = Set<String>()
    private var current: LANTransferOffer?
    private var phases: [String: LANTransferEvent.Kind] = [:]
    private var heldInventory: (LANInventoryRequest, CheckedContinuation<[String: Any], Error>)?

    func remember(_ track: PhoneTrack) throws {
        saved[LANInventoryWire.pathKey(folder: track.folder, fileName: track.fileName)] = Fingerprint(
            bytes: try TransferSourceVersion.read(track.url).byteCount, hash: try LANFileDigest.sha256(of: track.url))
    }

    func request(_ message: [String: Any]) async throws -> [String: Any] {
        if let request = LANTransferWire.decode(LANInventoryRequest.self, from: message, type: LANInventoryWire.requestType) {
            inventoryCount += 1
            if holdNextInventory {
                holdNextInventory = false
                return try await withCheckedThrowingContinuation { heldInventory = (request, $0) }
            }
            return try inventoryReply(request)
        }
        if let command = LANTransferWire.decode(LANTransferCommand.self, from: message, type: LANTransferWire.commandType) {
            if command.kind == .stop { stopCount += 1; pending.removeAll() }
            if command.kind == .pause || command.kind == .resume {
                for id in command.fileIDs ?? Array(pending) { phases[id] = command.kind == .pause ? .paused : .resumed }
            }
            let ids = command.fileIDs.map(Set.init) ?? pending
            let events = current?.files.filter { pending.contains($0.id) && ids.contains($0.id) }.map { file in
                LANTransferEvent(sessionID: current!.sessionID, fileID: file.id, kind: phases[file.id] ?? .resumed,
                                 completedBytes: 0, totalBytes: file.byteCount, message: nil, controlRevision: command.controlRevision)
            } ?? []
            return try LANTransferWire.message(LANTransferControlReply(events: events), type: LANTransferWire.controlReplyType)
        }
        if let offer = LANTransferWire.decode(LANTransferOffer.self, from: message, type: LANTransferWire.offerType) {
            guard pending.isEmpty else { throw PeerFailure.activeOfferReplaced }
            offers.append(offer); current = offer; pending = Set(offer.files.map(\.id)); phases = [:]
            return ["accepted": true]
        }
        throw PeerFailure.unknownMessage
    }

    func finish(_ file: LANTransferFile, in offer: LANTransferOffer, on library: PhoneLibrary,
                kind: LANTransferEvent.Kind = .stored) {
        pending.remove(file.id)
        if kind == .stored {
            saved[LANInventoryWire.pathKey(folder: file.folder, fileName: file.fileName)] = Fingerprint(bytes: file.byteCount, hash: file.sha256)
        }
        library.receiveTransferQueueProbeEvent(LANTransferEvent(sessionID: offer.sessionID, fileID: file.id, kind: kind,
            completedBytes: kind == .stored ? file.byteCount : 0, totalBytes: file.byteCount, message: kind == .failed ? "模拟失败" : nil))
    }

    func releaseInventory() {
        guard let (request, continuation) = heldInventory else { return }
        heldInventory = nil
        do { continuation.resume(returning: try inventoryReply(request)) }
        catch { continuation.resume(throwing: error) }
    }

    private func inventoryReply(_ request: LANInventoryRequest) throws -> [String: Any] {
        let matches = request.files.filter { file in
            guard let found = saved[LANInventoryWire.pathKey(folder: file.folder, fileName: file.fileName)] else { return false }
            return found.bytes == file.byteCount && found.hash == file.sha256
        }.map(\.id)
        return try LANTransferWire.message(LANInventoryReply(requestID: request.requestID, matchedFileIDs: matches), type: LANInventoryWire.replyType)
    }

    private enum PeerFailure: Error { case activeOfferReplaced, unknownMessage }
}
