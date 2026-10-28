import Darwin
import Foundation

/// Native PhoneLibrary/HTTP-source preparation with injected Watch replies and
/// background grants. This verifies application behavior, not OS scheduling.
@main
struct PhoneBackgroundQueueProbe {
    @MainActor private static var assertions = 0

    @MainActor static func main() async {
        do {
            try await run()
            print("PASS: \(assertions) phone background queue assertions")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("PHONE_BACKGROUND_QUEUE_FAIL: \(error.localizedDescription)\n".utf8))
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

    @MainActor private static func send(_ tracks: [PhoneTrack], on library: PhoneLibrary) async -> Set<String> {
        await withCheckedContinuation { continuation in
            library.send(tracks) { continuation.resume(returning: $0) }
        }
    }

    @MainActor private static func ready(_ count: Int, on library: PhoneLibrary, peer: BackgroundQueuePeer) async throws {
        try await wait("offer \(count): \(library.errorMessage ?? "no model error")") {
            peer.offers.count == count && !library.isPreparingLAN && !library.isAwaitingLANAcceptance
        }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count > 1, CommandLine.arguments.contains("-preview-transfers-in-progress") else {
            throw ProbeFailure.failed("Fixture and explicit isolated preview mode required")
        }
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard documents.path.contains("/CoreSimulator/Devices/") else { throw ProbeFailure.failed("Simulator only") }
        let music = documents.appendingPathComponent("Music", isDirectory: true)
        let musicExisted = manager.fileExists(atPath: music.path)
        let realIndexes = ["transfers.json", "lan-phone-queue.json"].map { documents.appendingPathComponent($0) }
        let realIndexBytes = realIndexes.map { try? Data(contentsOf: $0) }
        let prefix = "BackgroundQueueProbe-" + UUID().uuidString
        let folders = ["A", "B"].map { music.appendingPathComponent(prefix + "-" + $0, isDirectory: true) }
        let persistenceRoot = documents.appendingPathComponent(prefix + "-Persistence", isDirectory: true)
        var models: [PhoneLibrary] = []
        var peers: [BackgroundQueuePeer] = []
        defer {
            peers.forEach { $0.releaseInventory(); $0.releaseStatusUsingCurrentSession() }
            models.forEach { $0.clearAllTasks() }
            LANContinuedProcessing.shared.finish(success: false)
            folders.forEach { try? manager.removeItem(at: $0) }
            try? manager.removeItem(at: persistenceRoot)
            if !musicExisted, (try? manager.contentsOfDirectory(atPath: music.path).isEmpty) == true {
                try? manager.removeItem(at: music)
            }
        }
        for folder in folders { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        try manager.createDirectory(at: persistenceRoot, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        func track(_ folder: Int, _ name: String) throws -> PhoneTrack {
            let url = folders[folder].appendingPathComponent(name)
            try manager.copyItem(at: fixture, to: url)
            return PhoneTrack(folder: folders[folder].lastPathComponent, fileName: name, url: url,
                              bytes: try TransferSourceVersion.read(url).byteCount)
        }
        let a1 = try track(0, "one.mp3"), a2 = try track(0, "two.mp3")
        let b1 = try track(1, "one.mp3"), b2 = try track(1, "two.mp3")
        func directory(_ name: String) throws -> URL {
            let url = persistenceRoot.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func model(_ peer: BackgroundQueuePeer, at path: URL? = nil, automatic: Bool = true) -> PhoneLibrary {
            let library = PhoneLibrary()
            library.configureTransferQueueProbe(request: { try await peer.request($0) },
                persistenceDirectory: path, automaticallyGrantBackground: automatic)
            models.append(library); peers.append(peer)
            return library
        }
        func snapshot(_ path: URL) throws -> LANPhoneQueueSnapshot {
            try JSONDecoder().decode(LANPhoneQueueSnapshot.self,
                from: Data(contentsOf: path.appendingPathComponent("lan-phone-queue.json")))
        }

        // A foreground action gets a grant. Both already queued work and an
        // inventory request in flight continue after the real model transition.
        let continuedPeer = BackgroundQueuePeer()
        let continued = model(continuedPeer)
        _ = await send([a1, a2], on: continued)
        try await ready(1, on: continued, peer: continuedPeer)
        let first = continuedPeer.offers[0]
        try check(LANContinuedProcessing.shared.canRunInBackground, "Send action obtains the injected runtime grant")
        continuedPeer.holdNextInventory = true
        var appended: Set<String>?
        continued.send([b1, b2]) { appended = $0 }
        try await wait("append inventory held") { continuedPeer.hasHeldInventory }
        continued.sceneDidEnterBackground()
        try check(continued.isLANActive && continued.activeLANSessionID == first.sessionID,
                  "Granted background transition preserves the active source session")
        try check(continuedPeer.stops.isEmpty, "Granted background transition sends no stop")
        continuedPeer.releaseInventory()
        try await wait("append finishes in background") { appended != nil }
        try check(appended == [b1.id, b2.id] && continued.pendingCount == 4,
                  "Append preflight is allowed to finish while backgrounded")
        for file in first.files { continuedPeer.finish(file, in: first, on: continued) }
        try await ready(2, on: continued, peer: continuedPeer)
        let second = continuedPeer.offers[1]
        try check(second.sessionID != first.sessionID && second.files.map(\.fileName) == [b1.fileName, b2.fileName] &&
                  second.files.allSatisfy { $0.folder == b1.folder }, "A second batch starts in FIFO order without foregrounding")
        for file in second.files { continuedPeer.finish(file, in: second, on: continued) }
        try check(continued.storedTransfers.count == 4 && continued.pendingCount == 0 && !continued.isLANActive,
                  "Every background batch reaches its verified saved receipt")
        try check(!LANContinuedProcessing.shared.canRunInBackground, "The grant is released when all queue work is saved")
        continued.clearAllTasks()

        // Expiration/cancel preserves both the active tail and future queue,
        // and requires an explicit action even after returning to foreground.
        let parkedDirectory = try directory("parked")
        let parkedPeer = BackgroundQueuePeer()
        let parked = model(parkedPeer, at: parkedDirectory)
        _ = await send([a1, a2], on: parked)
        try await ready(1, on: parked, peer: parkedPeer)
        _ = await send([b1, b2], on: parked)
        let parkedFirst = parkedPeer.offers[0]
        parkedPeer.finish(parkedFirst.files[0], in: parkedFirst, on: parked)
        let remainingIDs = [parkedFirst.files[1].id, parked.latestTransfer(for: b1)!.id, parked.latestTransfer(for: b2)!.id]
        parked.sceneDidEnterBackground()
        LANContinuedProcessing.shared.interruptForProbe()
        try await wait("expiration preserves Watch partials") { !parkedPeer.stops.isEmpty }
        try check(!parked.isLANActive && !LANContinuedProcessing.shared.canRunInBackground,
                  "Expiration closes the volatile source and relinquishes runtime")
        try check(parked.transfers.filter { $0.state.isPending }.count == 3 &&
                  parked.transfers.filter { $0.state.isPending }.allSatisfy { $0.state == .paused && $0.resumesWhenForeground != true },
                  "Unfinished records are paused rather than failed after system cancellation")
        try check(!parked.transfers.contains { $0.state == .failed } && parked.storedTransfers.count == 1,
                  "Already saved facts survive expiration")
        try check(parkedPeer.stops.last?.preservePartialFiles == true, "Expiration asks Watch to retain validated partial files")
        let parkedSnapshot = try snapshot(parkedDirectory)
        try check(parkedSnapshot.orderedRecordIDs == remainingIDs && parkedSnapshot.globallyPaused,
                  "Persistent queue retains active-tail and future FIFO order")
        parked.sceneDidBecomeActive()
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(parkedPeer.offers.count == 1 && parked.transfers.filter { $0.state.isPending }.allSatisfy { $0.state == .paused },
                  "Foregrounding honors a system cancellation without automatic restart")
        parked.resumeTransfers()
        try await ready(2, on: parked, peer: parkedPeer)
        let parkedSecond = parkedPeer.offers[1]
        try check(LANContinuedProcessing.shared.canRunInBackground && parkedSecond.sessionID != parkedFirst.sessionID &&
                  parkedSecond.token != parkedFirst.token, "Explicit Start obtains new runtime and fresh source credentials")
        try check(parkedSecond.files.map(\.id) == remainingIDs, "Explicit recovery preserves every remaining record in order")
        parked.receiveTransferQueueProbeEvent(LANTransferEvent(sessionID: parkedFirst.sessionID,
            fileID: remainingIDs[0], kind: .cancelled, completedBytes: 0,
            totalBytes: parkedFirst.files[1].byteCount, message: "late old session"))
        try check(parked.transfers.first { $0.id == remainingIDs[0] }?.state == .queued,
                  "A late old-session event cannot cancel a freshly resumed transfer")
        for file in parkedSecond.files { parkedPeer.finish(file, in: parkedSecond, on: parked) }
        try check(parked.storedTransfers.count == 4 && parked.pendingCount == 0, "Resumed expiration queue finishes once per source")
        parked.clearAllTasks()

        // Crash-style persistence restore revalidates actual files, does not
        // trust historical grants, and preserves an individually paused song.
        let restartOriginal = try directory("restart-original")
        let restartPeer = BackgroundQueuePeer()
        let restart = model(restartPeer, at: restartOriginal)
        _ = await send([a1, a2, b1, b2], on: restart)
        try await ready(1, on: restart, peer: restartPeer)
        let original = restartPeer.offers[0]
        let manuallyPausedID = original.files[3].id
        restart.pauseTransfers(ids: [manuallyPausedID])
        try await wait("individual pause acknowledgment") { !restart.isUpdatingTransferControls }
        try check(restart.transfers.first { $0.id == manuallyPausedID }?.state == .paused,
                  "User pause is persisted before restart")
        let restartCopy = persistenceRoot.appendingPathComponent("restart-copy", isDirectory: true)
        try manager.copyItem(at: restartOriginal, to: restartCopy)
        let queueBytes = try Data(contentsOf: restartCopy.appendingPathComponent("lan-phone-queue.json"))
        let queueText = String(decoding: queueBytes, as: UTF8.self)
        try check(!queueText.contains(original.token) && !queueText.contains("http://"),
                  "Persistent queue stores no source credentials or endpoints")
        restart.clearAllTasks()
        try check(!restart.isLANActive, "Discarding the old model closes its source before simulated restart")
        let attributes = try manager.attributesOfItem(atPath: a2.url.path)
        let oldVersion = try TransferSourceVersion.read(a2.url)
        var changed = try Data(contentsOf: a2.url)
        changed[changed.startIndex] ^= 1
        try changed.write(to: a2.url)
        if let oldDate = attributes[.modificationDate] { try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: a2.url.path) }
        try check(try TransferSourceVersion.read(a2.url) != oldVersion && Int64(changed.count) == oldVersion.byteCount,
                  "Restart fixture changes actual content while preserving source size and mtime")
        let restoredPeer = BackgroundQueuePeer()
        let restored = model(restoredPeer, at: restartCopy)
        try restored.restoreTransferQueueForProbe()
        try check(!restored.isLANActive && restoredPeer.offers.isEmpty && !LANContinuedProcessing.shared.canRunInBackground,
                  "Restoring persistent work never resurrects an old source session or runtime grant")
        try check(restored.latestTransfer(for: a2)?.state == .outdated,
                  "A same-size modified source is refused during restart recovery")
        let automaticIDs = [original.files[0].id, original.files[2].id]
        try check(automaticIDs.allSatisfy { id in restored.transfers.contains { $0.id == id && $0.state == .paused && $0.resumesWhenForeground == true } },
                  "Unchanged interrupted work is marked waiting for foreground recovery")
        try check(restored.transfers.contains { $0.id == manuallyPausedID && $0.state == .paused && $0.resumesWhenForeground != true },
                  "User-paused work remains distinct from interrupted work")
        restored.sceneDidBecomeActive()
        try await ready(1, on: restored, peer: restoredPeer)
        let restoredOffer = restoredPeer.offers[0]
        try check(restoredOffer.files.map(\.id) == automaticIDs && restoredOffer.sessionID != original.sessionID,
                  "Foreground restore sends unchanged sources in persisted order using a new session")
        for file in restoredOffer.files { restoredPeer.finish(file, in: restoredOffer, on: restored) }
        try check(restored.transfers.first { $0.id == manuallyPausedID }?.state == .paused && restoredPeer.offers.count == 1,
                  "Completing restored work never bypasses the user's pause")
        restored.resumeTransfers(ids: [manuallyPausedID])
        try await ready(2, on: restored, peer: restoredPeer)
        try check(restoredPeer.offers[1].files.map(\.id) == [manuallyPausedID] && LANContinuedProcessing.shared.canRunInBackground,
                  "Explicit resume alone restarts the user-paused song with a fresh runtime grant")
        for file in restoredPeer.offers[1].files { restoredPeer.finish(file, in: restoredPeer.offers[1], on: restored) }
        restored.clearAllTasks()

        // Clearing during a held preflight invalidates both a late response
        // and a late background grant, without completing selection twice.
        let clearedPeer = BackgroundQueuePeer()
        let cleared = model(clearedPeer, automatic: false)
        clearedPeer.holdNextInventory = true
        var callbackCount = 0
        var clearedHandled = Set<String>()
        cleared.send([a1]) { callbackCount += 1; clearedHandled = $0 }
        try await wait("clear preflight held") { clearedPeer.hasHeldInventory }
        try check(LANContinuedProcessing.shared.isRequesting && !LANContinuedProcessing.shared.canRunInBackground,
                  "Submission pending is distinct from a granted background task")
        cleared.clearAllTasks()
        LANContinuedProcessing.shared.grantForProbe()
        clearedPeer.releaseInventory()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(callbackCount == 1 && clearedHandled.isEmpty, "Clear completes an unfinished selection exactly once")
        try check(cleared.transfers.isEmpty && clearedPeer.offers.isEmpty && !LANContinuedProcessing.shared.canRunInBackground,
                  "Late grant and preflight response cannot recreate a cleared queue")

        // An asynchronous grant may arrive just after the foreground transition.
        let handoffPeer = BackgroundQueuePeer()
        let handoff = model(handoffPeer, automatic: false)
        _ = await send([a1], on: handoff)
        try await ready(1, on: handoff, peer: handoffPeer)
        let handoffOffer = handoffPeer.offers[0]
        handoff.sceneDidEnterBackground()
        try check(handoff.isLANActive && handoffPeer.stops.isEmpty && LANContinuedProcessing.shared.isRequesting,
                  "A pending grant gets a bounded handoff window without immediate source stop")
        LANContinuedProcessing.shared.grantForProbe()
        try check(LANContinuedProcessing.shared.canRunInBackground && handoff.activeLANSessionID == handoffOffer.sessionID,
                  "A grant during handoff preserves the existing source session")
        handoffPeer.finish(handoffOffer.files[0], in: handoffOffer, on: handoff)
        try check(handoff.pendingCount == 0 && !LANContinuedProcessing.shared.canRunInBackground,
                  "Handoff grant completes and releases normally")

        // A refusal during handoff is recoverable and never reported as a file
        // failure. An explicit Start retries the system request and source.
        let refusedPeer = BackgroundQueuePeer()
        let refused = model(refusedPeer, automatic: false)
        _ = await send([a1], on: refused)
        try await ready(1, on: refused, peer: refusedPeer)
        refused.sceneDidEnterBackground()
        LANContinuedProcessing.shared.interruptForProbe()
        try await wait("refusal parks queue") { !refusedPeer.stops.isEmpty }
        try check(!refused.isLANActive && refused.transfers.count == 1 && refused.transfers[0].state == .paused &&
                  refusedPeer.stops.last?.preservePartialFiles == true,
                  "Grant refusal parks pending work and preserves partial files")
        refused.sceneDidBecomeActive()
        try check(refusedPeer.offers.count == 1 && refused.transfers[0].state == .paused,
                  "Foregrounding does not undo an explicitly interrupted request")
        refused.resumeTransfers()
        try check(LANContinuedProcessing.shared.isRequesting, "Start after refusal creates another runtime request")
        LANContinuedProcessing.shared.grantForProbe()
        try await ready(2, on: refused, peer: refusedPeer)
        try check(LANContinuedProcessing.shared.canRunInBackground &&
                  refusedPeer.offers[1].sessionID != refusedPeer.offers[0].sessionID,
                  "Refused task can resume into a new session after a fresh grant")
        refusedPeer.finish(refusedPeer.offers[1].files[0], in: refusedPeer.offers[1], on: refused)

        // The short handoff lease cannot become a permanent runtime loophole.
        let timeoutPeer = BackgroundQueuePeer()
        let timeout = model(timeoutPeer, automatic: false)
        _ = await send([a1], on: timeout)
        try await ready(1, on: timeout, peer: timeoutPeer)
        timeout.sceneDidEnterBackground()
        try await wait("ungranted handoff timeout") { !timeoutPeer.stops.isEmpty }
        try check(!timeout.isLANActive && timeout.transfers[0].state == .paused &&
                  timeout.transfers[0].resumesWhenForeground == true && timeoutPeer.stops[0].preservePartialFiles == true,
                  "Handoff timeout marks waiting recovery and closes the source safely")
        LANContinuedProcessing.shared.grantForProbe()
        try check(!LANContinuedProcessing.shared.canRunInBackground && timeoutPeer.offers.count == 1,
                  "A grant arriving after handoff expiry is ignored")
        timeout.sceneDidBecomeActive()
        try await ready(2, on: timeout, peer: timeoutPeer)
        try check(timeoutPeer.offers[1].files[0].id == timeoutPeer.offers[0].files[0].id,
                  "Foregrounding resumes handoff-timeout work using the retained task record")
        timeoutPeer.finish(timeoutPeer.offers[1].files[0], in: timeoutPeer.offers[1], on: timeout)

        // A status request from canceled preparation A may return after source
        // B is already live. Even if the reply names B, A must not stop it.
        let statusRacePeer = BackgroundQueuePeer()
        let statusRace = model(statusRacePeer)
        statusRacePeer.holdNextStatus = true
        _ = await send([a1], on: statusRace)
        try await wait("old preparation status held") { statusRacePeer.hasHeldStatus }
        try check(statusRace.isPreparingLAN && statusRacePeer.offers.isEmpty,
                  "Old preparation waits for its asynchronous status reply before offering")
        statusRace.clearAllTasks()
        try check(!statusRace.isLANActive && statusRace.transfers.isEmpty,
                  "Clear invalidates the old preparation while its status request is pending")
        _ = await send([b1], on: statusRace)
        try await ready(1, on: statusRace, peer: statusRacePeer)
        let liveReplacement = statusRacePeer.offers[0]
        statusRacePeer.releaseStatusUsingCurrentSession()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(statusRacePeer.stops.isEmpty && statusRace.activeLANSessionID == liveReplacement.sessionID &&
                  statusRace.latestTransfer(for: b1)?.state == .queued,
                  "Late status naming the replacement session cannot stop or mutate live work")
        statusRacePeer.finish(liveReplacement.files[0], in: liveReplacement, on: statusRace)
        try check(statusRace.pendingCount == 0 && statusRace.storedTransfers.count == 1,
                  "Replacement transfer finishes normally after canceled preparation's late status")

        for (index, url) in realIndexes.enumerated() {
            try check((try? Data(contentsOf: url)) == realIndexBytes[index], "Native probe leaves real \(url.lastPathComponent) untouched")
        }
        for item in [a1, a2, b1, b2] { try check(manager.fileExists(atPath: item.url.path), "Queue recovery preserves source \(item.id)") }
    }

    private enum ProbeFailure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}

@MainActor
private final class BackgroundQueuePeer {
    struct Fingerprint { let bytes: Int64; let hash: String }
    var saved: [String: Fingerprint] = [:]
    var offers: [LANTransferOffer] = []
    var stops: [LANTransferCommand] = []
    var holdNextInventory = false
    var hasHeldInventory: Bool { heldInventory != nil }
    var holdNextStatus = false
    var hasHeldStatus: Bool { heldStatus != nil }
    private var current: LANTransferOffer?
    private var pending = Set<String>()
    private var phases: [String: LANTransferEvent.Kind] = [:]
    private var heldInventory: (LANInventoryRequest, CheckedContinuation<[String: Any], Error>)?
    private var heldStatus: CheckedContinuation<[String: Any], Error>?

    func request(_ message: [String: Any]) async throws -> [String: Any] {
        if let request = LANTransferWire.decode(LANInventoryRequest.self, from: message, type: LANInventoryWire.requestType) {
            if holdNextInventory {
                holdNextInventory = false
                return try await withCheckedThrowingContinuation { heldInventory = (request, $0) }
            }
            return try inventoryReply(request)
        }
        if let command = LANTransferWire.decode(LANTransferCommand.self, from: message, type: LANTransferWire.commandType) {
            if command.kind == .status, holdNextStatus {
                holdNextStatus = false
                return try await withCheckedThrowingContinuation { heldStatus = $0 }
            }
            if command.kind == .stop {
                stops.append(command); pending.removeAll()
            } else if command.kind == .cancel {
                if let id = command.fileID { pending.remove(id) }
                else if let ids = command.fileIDs { pending.subtract(ids) }
            } else if command.kind == .pause || command.kind == .resume {
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

    func finish(_ file: LANTransferFile, in offer: LANTransferOffer, on library: PhoneLibrary) {
        pending.remove(file.id)
        saved[LANInventoryWire.pathKey(folder: file.folder, fileName: file.fileName)] = Fingerprint(bytes: file.byteCount, hash: file.sha256)
        library.receiveTransferQueueProbeEvent(LANTransferEvent(sessionID: offer.sessionID, fileID: file.id,
            kind: .stored, completedBytes: file.byteCount, totalBytes: file.byteCount, message: nil))
    }

    func releaseInventory() {
        guard let (request, continuation) = heldInventory else { return }
        heldInventory = nil
        do { continuation.resume(returning: try inventoryReply(request)) }
        catch { continuation.resume(throwing: error) }
    }

    func releaseStatusUsingCurrentSession() {
        guard let continuation = heldStatus else { return }
        heldStatus = nil
        let events = current?.files.filter { pending.contains($0.id) }.map { file in
            LANTransferEvent(sessionID: current!.sessionID, fileID: file.id, kind: .resumed,
                completedBytes: 0, totalBytes: file.byteCount, message: nil)
        } ?? []
        do {
            continuation.resume(returning: try LANTransferWire.message(LANTransferControlReply(events: events),
                type: LANTransferWire.controlReplyType))
        } catch { continuation.resume(throwing: error) }
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
