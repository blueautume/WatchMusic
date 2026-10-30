import Darwin
import Foundation

/// Native PhoneLibrary/filesystem/source preparation with an injected Watch.
/// These checks exercise lifecycle policy, not real device scene transitions.
@main
struct PhoneForegroundQueueProbe {
    @MainActor private static var assertions = 0

    @MainActor static func main() async {
        do {
            try await run()
            print("PASS: \(assertions) phone foreground queue assertions")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("PHONE_FOREGROUND_QUEUE_FAIL: \(error.localizedDescription)\n".utf8))
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

    @MainActor private static func ready(_ count: Int, on library: PhoneLibrary, peer: ForegroundQueuePeer) async throws {
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
        let prefix = "ForegroundQueueProbe-" + UUID().uuidString
        let folders = ["A", "B"].map { music.appendingPathComponent(prefix + "-" + $0, isDirectory: true) }
        let persistenceRoot = documents.appendingPathComponent(prefix + "-Persistence", isDirectory: true)
        var models: [PhoneLibrary] = []
        var peers: [ForegroundQueuePeer] = []
        defer {
            peers.forEach { $0.releaseInventory(); $0.releaseStatusUsingCurrentSession(); $0.releaseResume() }
            models.forEach { $0.sceneDidBecomeInactive(); $0.clearAllTasks() }
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
        func model(_ peer: ForegroundQueuePeer, at path: URL? = nil) -> PhoneLibrary {
            let library = PhoneLibrary()
            library.configureTransferQueueProbe(request: { try await peer.request($0) }, persistenceDirectory: path)
            models.append(library); peers.append(peer)
            return library
        }
        func snapshot(_ path: URL) throws -> LANPhoneQueueSnapshot {
            try JSONDecoder().decode(LANPhoneQueueSnapshot.self,
                from: Data(contentsOf: path.appendingPathComponent("lan-phone-queue.json")))
        }

        // Control Center/inactive must pause before the later background event.
        // Restore the current tail before the second list, without re-sending a
        // saved song or replacing manual pause intent.
        let activeDirectory = try directory("active")
        let activePeer = ForegroundQueuePeer()
        let active = model(activePeer, at: activeDirectory)
        _ = await send([a1, a2], on: active)
        try await ready(1, on: active, peer: activePeer)
        _ = await send([b1, b2], on: active)
        let first = activePeer.offers[0]
        activePeer.finish(first.files[0], in: first, on: active)
        let remainingIDs = [first.files[1].id, active.latestTransfer(for: b1)!.id, active.latestTransfer(for: b2)!.id]
        active.sceneDidBecomeInactive()
        try await wait("inactive source pauses") { !activePeer.automaticPauses.isEmpty }
        try check(!active.isLANActive && active.pendingCount == 3 && active.storedTransfers.count == 1,
                  "Inactive closes the source while preserving the saved fact and pending queue")
        try check(active.transfers.filter { $0.state.isPending }.allSatisfy { $0.state == .paused && $0.resumesWhenForeground == true },
                  "Inactive work is automatically paused rather than failed or canceled")
        try check(!active.transfers.contains { $0.state == .failed }, "Control Center is not a file-transfer failure")
        let pausedSnapshot = try snapshot(activeDirectory)
        try check(pausedSnapshot.orderedRecordIDs == remainingIDs && !pausedSnapshot.globallyPaused,
                  "Automatic pause persists active-tail and later-list FIFO without global user pause")
        active.sceneDidEnterBackground()
        active.retryAutomaticTransfersForProbe()
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(activePeer.offers.count == 1 && !active.isLANActive,
                  "Inactive followed by background cannot launch a replacement source")
        active.sceneDidBecomeActive()
        try await ready(2, on: active, peer: activePeer)
        let recovered = activePeer.offers[1]
        try check(recovered.files.map(\.id) == remainingIDs && recovered.sessionID != first.sessionID && recovered.token != first.token,
                  "Foreground automatically restores remaining FIFO with fresh source credentials")
        active.receiveTransferQueueProbeEvent(LANTransferEvent(sessionID: first.sessionID, fileID: remainingIDs[0],
            kind: .cancelled, completedBytes: 0, totalBytes: first.files[1].byteCount, message: "late old session"))
        try check(active.transfers.first { $0.id == remainingIDs[0] }?.state == .queued,
                  "A canceled old session cannot cancel the resumed record")
        for file in recovered.files { activePeer.finish(file, in: recovered, on: active) }
        try check(active.storedTransfers.count == 4 && active.pendingCount == 0,
                  "Automatic foreground recovery finishes each remaining song once")
        let skipped = await send([a1, a2, b1, b2], on: active)
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(skipped == [a1.id, a2.id, b1.id, b2.id] && activePeer.offers.count == 2 && active.pendingCount == 0,
                  "Already saved files are checked against Watch inventory and do not re-enter the queue")
        active.clearAllTasks()

        // A direct background transition follows the same rule as inactive.
        let backgroundPeer = ForegroundQueuePeer()
        let background = model(backgroundPeer)
        _ = await send([a1, a2], on: background)
        try await ready(1, on: background, peer: backgroundPeer)
        background.sceneDidEnterBackground()
        try await wait("background source pauses") { !backgroundPeer.automaticPauses.isEmpty }
        try check(!background.isLANActive && background.transfers.allSatisfy { $0.state == .paused && $0.resumesWhenForeground == true },
                  "Background preserves unfinished records for automatic recovery")
        background.sceneDidBecomeActive()
        try await ready(2, on: background, peer: backgroundPeer)
        for file in backgroundPeer.offers[1].files { backgroundPeer.finish(file, in: backgroundPeer.offers[1], on: background) }
        try check(background.pendingCount == 0 && background.storedTransfers.count == 2,
                  "A direct background/active cycle needs no manual retry")
        background.clearAllTasks()

        // Manual per-song and global pauses survive lifecycle changes.
        let manualPeer = ForegroundQueuePeer()
        let manual = model(manualPeer)
        _ = await send([a1, a2], on: manual)
        try await ready(1, on: manual, peer: manualPeer)
        let manualFirst = manualPeer.offers[0]
        let manualID = manualFirst.files[1].id
        manual.pauseTransfers(ids: [manualID])
        try await wait("individual pause") { !manual.isUpdatingTransferControls }
        manual.sceneDidBecomeInactive()
        try await wait("manual source closes for inactive") { !manualPeer.automaticPauses.isEmpty }
        try check(manual.transfers.contains { $0.id == manualID && $0.state == .paused && $0.resumesWhenForeground != true },
                  "Automatic parking never overwrites a manual per-song pause")
        manual.sceneDidBecomeActive()
        try await ready(2, on: manual, peer: manualPeer)
        try check(manualPeer.offers[1].files.map(\.id) == [manualFirst.files[0].id],
                  "Only automatically paused songs restart on active")
        manualPeer.finish(manualPeer.offers[1].files[0], in: manualPeer.offers[1], on: manual)
        manual.retryAutomaticTransfersForProbe()
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(manualPeer.offers.count == 2 && manual.transfers.first { $0.id == manualID }?.state == .paused,
                  "Automatic retry does not restart the manually paused tail")
        manual.resumeTransfers(ids: [manualID])
        try await ready(3, on: manual, peer: manualPeer)
        manualPeer.finish(manualPeer.offers[2].files[0], in: manualPeer.offers[2], on: manual)
        manual.clearAllTasks()

        // Once Start is tapped, that newer intent must survive an inactive
        // transition even if the old Watch resume acknowledgment is delayed.
        let resumePeer = ForegroundQueuePeer()
        let resumeRace = model(resumePeer)
        _ = await send([a1], on: resumeRace)
        try await ready(1, on: resumeRace, peer: resumePeer)
        let resumeOriginal = resumePeer.offers[0]
        let resumeID = resumeOriginal.files[0].id
        resumeRace.pauseTransfers(ids: [resumeID])
        try await wait("resume race manual pause acknowledged") { !resumeRace.isUpdatingTransferControls }
        try check(resumeRace.transfers.first { $0.id == resumeID }?.state == .paused,
                  "Resume-race fixture starts from an acknowledged user pause")
        resumePeer.holdNextResume = true
        resumeRace.resumeTransfers(ids: [resumeID])
        try await wait("resume acknowledgment held") { resumePeer.hasHeldResume }
        try check(resumeRace.transfers.first { $0.id == resumeID }?.resumesWhenForeground == true,
                  "Start persists automatic recovery intent before the resume acknowledgment arrives")
        resumeRace.sceneDidBecomeInactive()
        try await wait("resume race inactive source pause") { !resumePeer.automaticPauses.isEmpty }
        try check(!resumeRace.isLANActive && resumeRace.transfers.contains {
            $0.id == resumeID && $0.state == .paused && $0.resumesWhenForeground == true
        }, "Inactive preserves the newer Start intent instead of restoring the earlier user pause")
        resumeRace.sceneDidBecomeActive()
        try await ready(2, on: resumeRace, peer: resumePeer)
        let resumedSource = resumePeer.offers[1]
        try check(resumedSource.files.map(\.id) == [resumeID] && resumedSource.sessionID != resumeOriginal.sessionID,
                  "Foreground automatically retries the already requested Start in a fresh session")
        let stopsBeforeOldResume = resumePeer.stops.count
        resumePeer.releaseResume()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(resumeRace.activeLANSessionID == resumedSource.sessionID && !resumeRace.isUpdatingTransferControls &&
                  resumeRace.transfers.first { $0.id == resumeID }?.state == .queued &&
                  resumePeer.offers.count == 2 && resumePeer.stops.count == stopsBeforeOldResume,
                  "The old resume acknowledgment cannot pause, replace, or stop the new source")
        resumePeer.finish(resumedSource.files[0], in: resumedSource, on: resumeRace)
        try check(resumeRace.pendingCount == 0 && resumeRace.storedTransfers.count == 1,
                  "The fresh source completes normally after its stale resume response")
        resumeRace.clearAllTasks()

        let globalPeer = ForegroundQueuePeer()
        let globalDirectory = try directory("global")
        let global = model(globalPeer, at: globalDirectory)
        _ = await send([a1, a2], on: global)
        try await ready(1, on: global, peer: globalPeer)
        global.pauseTransfers()
        try await wait("global user pause") { !global.isUpdatingTransferControls }
        global.sceneDidEnterBackground()
        try await wait("globally paused source closed") { !globalPeer.automaticPauses.isEmpty }
        global.sceneDidBecomeActive()
        global.setTransferQueueProbeReachable(false)
        global.setTransferQueueProbeReachable(true)
        global.retryAutomaticTransfersForProbe()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(globalPeer.offers.count == 1 && global.transfers.allSatisfy { $0.state == .paused },
                  "Active and reconnect preserve a global manual pause")
        try check(try snapshot(globalDirectory).globallyPaused, "Global pause is persisted for process restore")
        global.clearAllTasks()

        // A fresh process must restore order and pause intent, revalidate source
        // content, and never trust obsolete source endpoints or credentials.
        let restartOriginal = try directory("restart-original")
        let restartPeer = ForegroundQueuePeer()
        let restart = model(restartPeer, at: restartOriginal)
        _ = await send([a1, a2, b1, b2], on: restart)
        try await ready(1, on: restart, peer: restartPeer)
        let original = restartPeer.offers[0]
        let userPausedID = original.files[3].id
        restart.pauseTransfers(ids: [userPausedID])
        try await wait("persistent per-song pause") { !restart.isUpdatingTransferControls }
        let restartCopy = persistenceRoot.appendingPathComponent("restart-copy", isDirectory: true)
        try manager.copyItem(at: restartOriginal, to: restartCopy)
        let queueText = String(decoding: try Data(contentsOf: restartCopy.appendingPathComponent("lan-phone-queue.json")), as: UTF8.self)
        try check(!queueText.contains(original.token) && !queueText.contains("http://"),
                  "Persistent recovery stores neither bearer credentials nor source URLs")
        restart.clearAllTasks()
        let oldVersion = try TransferSourceVersion.read(a2.url)
        let oldAttributes = try manager.attributesOfItem(atPath: a2.url.path)
        var changed = try Data(contentsOf: a2.url)
        changed[changed.startIndex] ^= 1
        try changed.write(to: a2.url)
        if let oldDate = oldAttributes[.modificationDate] { try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: a2.url.path) }
        try check(try TransferSourceVersion.read(a2.url) != oldVersion && Int64(changed.count) == oldVersion.byteCount,
                  "Restart fixture changes content while retaining size and old mtime")
        let sameContents = try Data(contentsOf: b1.url)
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: b1.url.path)
        let restoredPeer = ForegroundQueuePeer()
        let restored = model(restoredPeer, at: restartCopy)
        try restored.restoreTransferQueueForProbe()
        restored.sceneDidBecomeInactive()
        try check(!restored.isLANActive && restoredPeer.offers.isEmpty,
                  "Restoring persisted work cannot start a source before active")
        try check(restored.transfers.contains { $0.id == userPausedID && $0.state == .paused && $0.resumesWhenForeground != true },
                  "Process recovery retains explicit per-song pause intent")
        restored.sceneDidBecomeActive()
        try await ready(1, on: restored, peer: restoredPeer)
        let restoredOffer = restoredPeer.offers[0]
        try check(restoredOffer.files.map(\.id) == [original.files[0].id, original.files[2].id],
                  "Restart automatically restores valid runnable songs in the saved order")
        try check(restored.latestTransfer(for: a2)?.state == .outdated,
                  "Changed source content is refused rather than sent under the old fingerprint")
        try check(try Data(contentsOf: b1.url) == sameContents && restoredOffer.files.contains { $0.id == original.files[2].id },
                  "A metadata-only source change is rehashed and remains eligible")
        for file in restoredOffer.files { restoredPeer.finish(file, in: restoredOffer, on: restored) }
        try check(restored.transfers.first { $0.id == userPausedID }?.state == .paused && restoredPeer.offers.count == 1,
                  "Completing recovered songs does not bypass a user's paused song")
        restored.clearAllTasks()

        // An inactive transition during inventory preflight retains the user's
        // selection; the late old response cannot create a second offer.
        let preflightDirectory = try directory("preflight")
        let preflightPeer = ForegroundQueuePeer()
        let preflight = model(preflightPeer, at: preflightDirectory)
        preflightPeer.holdNextInventory = true
        var preflightCallbacks = 0
        preflight.send([a1]) { _ in preflightCallbacks += 1 }
        try await wait("preflight before inactive") { preflightPeer.hasHeldInventory }
        preflight.sceneDidBecomeInactive()
        let preflightSnapshot = try snapshot(preflightDirectory)
        try check(!preflight.isLANActive && preflightSnapshot.submissions.flatMap { $0 }.contains {
            $0.folder == a1.folder && $0.fileName == a1.fileName
        }, "Inactive persists a selected song even before it receives a transfer record")
        preflight.sceneDidBecomeActive()
        try await ready(1, on: preflight, peer: preflightPeer)
        preflightPeer.releaseInventory()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(preflightPeer.offers.count == 1 && preflight.pendingCount == 1 && preflightCallbacks == 1,
                  "Resumed preflight produces one offer and one completion despite its stale inventory reply")
        preflightPeer.finish(preflightPeer.offers[0].files[0], in: preflightPeer.offers[0], on: preflight)
        preflight.clearAllTasks()

        // A Watch lifecycle cancellation is a temporary connection condition.
        // Keep the selected files and retry through the existing queue rather
        // than treating the new optional refusal marker as a version mismatch.
        let inventoryPauseDirectory = try directory("watch-inventory-pause")
        let inventoryPausePeer = ForegroundQueuePeer()
        let inventoryPause = model(inventoryPausePeer, at: inventoryPauseDirectory)
        inventoryPausePeer.rejectNextInventoryTemporarily = true
        var inventoryPauseCallbacks = 0
        inventoryPause.send([a1]) { _ in inventoryPauseCallbacks += 1 }
        try await wait("Watch inventory lifecycle refusal") { inventoryPausePeer.inventoryRefusals == 1 }
        try check(inventoryPause.errorMessage == nil && inventoryPauseCallbacks == 0,
                  "Temporary Watch inventory cancellation does not complete the selection or show an upgrade error")
        try check(try snapshot(inventoryPauseDirectory).submissions.flatMap { $0 }.contains {
            $0.folder == a1.folder && $0.fileName == a1.fileName
        }, "Watch inventory cancellation preserves the persisted submission")
        try await ready(1, on: inventoryPause, peer: inventoryPausePeer)
        try check(inventoryPauseCallbacks == 1 && inventoryPause.pendingCount == 1,
                  "Automatic retry after Watch inventory cancellation produces one offer and one completion")
        inventoryPausePeer.finish(inventoryPausePeer.offers[0].files[0], in: inventoryPausePeer.offers[0], on: inventoryPause)
        inventoryPause.clearAllTasks()

        // Clearing an unfinished preflight cancels its completion once and
        // cannot be undone by lifecycle changes or its late Watch response.
        let clearPeer = ForegroundQueuePeer()
        let clear = model(clearPeer)
        clearPeer.holdNextInventory = true
        var callbackCount = 0
        var clearedHandled = Set<String>()
        clear.send([a1]) { callbackCount += 1; clearedHandled = $0 }
        try await wait("held preflight before clear") { clearPeer.hasHeldInventory }
        clear.sceneDidBecomeInactive()
        clear.clearAllTasks()
        clear.sceneDidBecomeActive()
        clearPeer.releaseInventory()
        clear.retryAutomaticTransfersForProbe()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(callbackCount == 1 && clearedHandled.isEmpty, "Clear completes selection exactly once")
        try check(clear.transfers.isEmpty && clearPeer.offers.isEmpty && !clear.isLANActive,
                  "Clear stays empty after foregrounding and a stale inventory response")

        // A cleared preparation's status reply can name a newer live session;
        // it must not be allowed to stop that source before checking its epoch.
        let statusPeer = ForegroundQueuePeer()
        let statusRace = model(statusPeer)
        statusPeer.holdNextStatus = true
        _ = await send([a1], on: statusRace)
        try await wait("old preparation status held") { statusPeer.hasHeldStatus }
        try check(statusRace.isPreparingLAN && statusPeer.offers.isEmpty,
                  "Preparation A has not offered songs while its status response is held")
        statusRace.clearAllTasks()
        try check(!statusRace.isLANActive && statusRace.transfers.isEmpty,
                  "Clear invalidates preparation A before its status response arrives")
        _ = await send([b1], on: statusRace)
        try await ready(1, on: statusRace, peer: statusPeer)
        let statusReplacement = statusPeer.offers[0]
        let stopsBeforeStaleStatus = statusPeer.stops.count
        statusPeer.releaseStatusUsingCurrentSession()
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(statusPeer.stops.count == stopsBeforeStaleStatus && statusPeer.offers.count == 1 &&
                  statusRace.activeLANSessionID == statusReplacement.sessionID &&
                  statusRace.latestTransfer(for: b1)?.state == .queued,
                  "A's late status naming B cannot stop or mutate the accepted replacement session")
        statusPeer.finish(statusReplacement.files[0], in: statusReplacement, on: statusRace)
        try check(statusRace.pendingCount == 0 && statusRace.storedTransfers.count == 1,
                  "Replacement B finishes after the canceled preparation's stale status")
        statusRace.clearAllTasks()

        // Brief unreachability parks work. Repeated recovery triggers cannot
        // build concurrent sources or break the resumed source session.
        let networkPeer = ForegroundQueuePeer()
        let network = model(networkPeer)
        _ = await send([a1, b1], on: network)
        try await ready(1, on: network, peer: networkPeer)
        let networkFirst = networkPeer.offers[0]
        network.setTransferQueueProbeReachable(false)
        try await wait("unreachable source parks") { !networkPeer.automaticPauses.isEmpty }
        try check(!network.isLANActive && network.transfers.allSatisfy { $0.state == .paused && $0.resumesWhenForeground == true },
                  "A temporary connection loss preserves automatically resumable records")
        for _ in 0..<5 { network.retryAutomaticTransfersForProbe() }
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(networkPeer.offers.count == 1 && networkPeer.offerAttempts == 1,
                  "Unreachable retry triggers do not repeatedly submit offers")
        network.setTransferQueueProbeReachable(true)
        network.retryAutomaticTransfersForProbe()
        try await ready(2, on: network, peer: networkPeer)
        let networkRecovered = networkPeer.offers[1]
        let stoppedBeforeRetry = networkPeer.stops.count
        for _ in 0..<5 { network.retryAutomaticTransfersForProbe() }
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(networkPeer.offers.count == 2 && networkPeer.offerAttempts == 2 &&
                  networkPeer.stops.count == stoppedBeforeRetry && network.activeLANSessionID == networkRecovered.sessionID,
                  "Repeated reconnect signals leave the single recovered source intact")
        try check(networkRecovered.files.map(\.id) == networkFirst.files.map(\.id),
                  "Network recovery preserves queue identities and FIFO")
        for file in networkRecovered.files { networkPeer.finish(file, in: networkRecovered, on: network) }
        network.clearAllTasks()

        // A temporary handshake failure also recovers, and explicit retry
        // triggers coalesce rather than parallelizing preparation or offers.
        let refusedPeer = ForegroundQueuePeer()
        refusedPeer.rejectNextOffer = true
        let refused = model(refusedPeer)
        _ = await send([b1], on: refused)
        try await wait("temporary offer rejection") { refusedPeer.offerAttempts == 1 && !refused.isLANActive }
        try check(refused.transfers.count == 1 && refused.transfers[0].state == .paused &&
                  refused.transfers[0].resumesWhenForeground == true,
                  "A temporary source handshake rejection retains a recoverable queue")
        for _ in 0..<5 { refused.retryAutomaticTransfersForProbe() }
        try await ready(1, on: refused, peer: refusedPeer)
        try check(refusedPeer.offerAttempts == 2, "Retries coalesce into one successful handshake")
        refusedPeer.finish(refusedPeer.offers[0].files[0], in: refusedPeer.offers[0], on: refused)
        refused.clearAllTasks()

        // Watch lifecycle notifications follow automatic pause semantics too.
        let watchPeer = ForegroundQueuePeer()
        let watch = model(watchPeer)
        _ = await send([a1, b1], on: watch)
        try await ready(1, on: watch, peer: watchPeer)
        let watchFirst = watchPeer.offers[0]
        let watchFile = watchFirst.files[0]
        watch.receiveTransferQueueProbeEvent(LANTransferEvent(sessionID: watchFirst.sessionID, fileID: watchFile.id,
            kind: .paused, completedBytes: 0, totalBytes: watchFile.byteCount, message: "Watch inactive", automaticPause: true))
        try await wait("Watch inactive parks source") { !watch.isLANActive && !watchPeer.automaticPauses.isEmpty }
        try check(watch.transfers.allSatisfy { $0.state == .paused && $0.resumesWhenForeground == true },
                  "Watch inactive preserves the entire queue as an automatic pause")
        watch.receiveTransferQueueProbeEvent(LANTransferEvent(sessionID: watchFirst.sessionID, fileID: watchFile.id,
            kind: .resumed, completedBytes: 0, totalBytes: watchFile.byteCount, message: "Watch active", automaticPause: true))
        try await ready(2, on: watch, peer: watchPeer)
        try check(watchPeer.offers[1].sessionID != watchFirst.sessionID &&
                  watchPeer.offers[1].files.map(\.id) == watchFirst.files.map(\.id),
                  "Watch active automatically rechecks and resumes the saved FIFO in a fresh session")
        for file in watchPeer.offers[1].files { watchPeer.finish(file, in: watchPeer.offers[1], on: watch) }
        watch.clearAllTasks()

        // Privacy withdrawal retires an existing model, including callbacks
        // already in flight. Re-agreement restores intent in a fresh model.
        let withdrawalRoot = try directory("privacy-withdrawal")
        let withdrawalPeer = ForegroundQueuePeer()
        let withdrawal = model(withdrawalPeer, at: withdrawalRoot)
        _ = await send([a1, b1], on: withdrawal)
        try await ready(1, on: withdrawal, peer: withdrawalPeer)
        let withdrawalOffer = withdrawalPeer.offers[0]
        let manualFile = withdrawalOffer.files[1]
        withdrawal.pauseTransfers(ids: [manualFile.id])
        try await wait("manual pause before withdrawal") {
            !withdrawal.isUpdatingTransferControls && withdrawal.transfers.first { $0.id == manualFile.id }?.state == .paused
        }
        withdrawal.shutdownForPrivacyWithdrawal()
        withdrawal.shutdownForPrivacyWithdrawal()
        let withdrawnTransfers = try Data(contentsOf: withdrawalRoot.appendingPathComponent("transfers.json"))
        let withdrawnQueue = try Data(contentsOf: withdrawalRoot.appendingPathComponent("lan-phone-queue.json"))
        try check(!withdrawal.isLANActive && !withdrawal.canSend && !withdrawal.isImporting,
                  "Withdrawal closes the source and disables business work idempotently")
        try check(withdrawal.transfers.allSatisfy { $0.state == .paused } &&
                  withdrawal.transfers.first { $0.id == manualFile.id }?.resumesWhenForeground == false,
                  "Withdrawal parks active work and preserves the user's separate manual pause")
        withdrawal.sceneDidBecomeActive()
        withdrawal.setTransferQueueProbeReachable(true)
        withdrawal.retryAutomaticTransfersForProbe()
        withdrawal.receiveTransferQueueProbeEvent(LANTransferEvent(sessionID: withdrawalOffer.sessionID,
            fileID: withdrawalOffer.files[0].id, kind: .stored, completedBytes: withdrawalOffer.files[0].byteCount,
            totalBytes: withdrawalOffer.files[0].byteCount, message: nil))
        withdrawal.clearAllTasks()
        withdrawal.clearCompletedTransfers()
        withdrawal.importFiles([fixture], into: PhoneFolder(name: folders[0].lastPathComponent))
        let refusedAfterWithdrawal = await send([a2], on: withdrawal)
        try check(refusedAfterWithdrawal.isEmpty && !withdrawal.createFolder(prefix + "-withdrawn"),
                  "A retired model rejects both new transfer submissions and file mutations")
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(withdrawalPeer.offers.count == 1 && !withdrawal.isLANActive &&
                  (try? Data(contentsOf: withdrawalRoot.appendingPathComponent("transfers.json"))) == withdrawnTransfers &&
                  (try? Data(contentsOf: withdrawalRoot.appendingPathComponent("lan-phone-queue.json"))) == withdrawnQueue,
                  "Late receipts and foreground callbacks cannot restart or rewrite a retired model")
        let agreedAgain = model(withdrawalPeer, at: withdrawalRoot)
        try agreedAgain.restoreTransferQueueForProbe()
        try check(agreedAgain.transfers.first { $0.id == manualFile.id }?.resumesWhenForeground == false,
                  "A new model restores the manual pause without changing consent-related saved intent")
        agreedAgain.sceneDidBecomeActive()
        try await ready(2, on: agreedAgain, peer: withdrawalPeer)
        let afterConsent = withdrawalPeer.offers[1]
        try check(afterConsent.files.map(\.id) == [withdrawalOffer.files[0].id],
                  "Re-agreement resumes only automatically parked work in FIFO order")
        withdrawalPeer.finish(afterConsent.files[0], in: afterConsent, on: agreedAgain)
        agreedAgain.resumeTransfers(ids: [manualFile.id])
        try await ready(3, on: agreedAgain, peer: withdrawalPeer)
        withdrawalPeer.finish(withdrawalPeer.offers[2].files[0], in: withdrawalPeer.offers[2], on: agreedAgain)
        try check(agreedAgain.pendingCount == 0 && agreedAgain.storedTransfers.count == 2,
                  "The independently paused item resumes only after the user's explicit start")
        agreedAgain.clearAllTasks()

        let importCancellation = PhoneImportCancellation()
        importCancellation.cancel()
        do {
            _ = try PhoneResourceImport.audio(fixture, into: folders[0], cancellation: importCancellation)
            throw ProbeFailure.failed("A cancelled importer must not commit a file")
        } catch is CancellationError {
            try check(true, "An importer cancelled before coordination cannot create a local copy")
        }

        for (index, url) in realIndexes.enumerated() {
            try check((try? Data(contentsOf: url)) == realIndexBytes[index], "Probe leaves real \(url.lastPathComponent) untouched")
        }
        for item in [a1, a2, b1, b2] { try check(manager.fileExists(atPath: item.url.path), "Pause/retry preserves source \(item.id)") }
    }

    private enum ProbeFailure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}

@MainActor
private final class ForegroundQueuePeer {
    struct Fingerprint { let bytes: Int64; let hash: String }
    var saved: [String: Fingerprint] = [:]
    var offers: [LANTransferOffer] = []
    var offerAttempts = 0
    var rejectNextOffer = false
    var stops: [LANTransferCommand] = []
    var automaticPauses: [LANTransferCommand] = []
    var holdNextInventory = false
    var rejectNextInventoryTemporarily = false
    var inventoryRefusals = 0
    var hasHeldInventory: Bool { heldInventory != nil }
    var holdNextStatus = false
    var hasHeldStatus: Bool { heldStatus != nil }
    var holdNextResume = false
    var hasHeldResume: Bool { heldResume != nil }
    private var current: LANTransferOffer?
    private var pending = Set<String>()
    private var phases: [String: LANTransferEvent.Kind] = [:]
    private var heldInventory: (LANInventoryRequest, CheckedContinuation<[String: Any], Error>)?
    private var heldStatus: CheckedContinuation<[String: Any], Error>?
    private var heldResume: ([LANTransferEvent], CheckedContinuation<[String: Any], Error>)?

    func request(_ message: [String: Any]) async throws -> [String: Any] {
        if let request = LANTransferWire.decode(LANInventoryRequest.self, from: message, type: LANInventoryWire.requestType) {
            if rejectNextInventoryTemporarily {
                rejectNextInventoryTemporarily = false
                inventoryRefusals += 1
                return ["accepted": false, "retryable": true, "message": "等待手表 App 打开后继续"]
            }
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
            if command.kind == .resume, command.automaticPause != true, holdNextResume {
                holdNextResume = false
                let ids = command.fileIDs.map(Set.init) ?? pending
                let events = current?.files.filter { pending.contains($0.id) && ids.contains($0.id) }.map { file in
                    LANTransferEvent(sessionID: command.sessionID, fileID: file.id, kind: .resumed,
                        completedBytes: 0, totalBytes: file.byteCount, message: nil, controlRevision: command.controlRevision)
                } ?? []
                return try await withCheckedThrowingContinuation { heldResume = (events, $0) }
            }
            if command.kind == .stop {
                stops.append(command); pending.removeAll()
            } else if command.kind == .cancel {
                if let id = command.fileID { pending.remove(id) }
                else if let ids = command.fileIDs { pending.subtract(ids) }
            } else if command.kind == .pause || command.kind == .resume {
                if command.kind == .pause && command.automaticPause == true { automaticPauses.append(command) }
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
            offerAttempts += 1
            if rejectNextOffer {
                rejectNextOffer = false
                throw NSError(domain: "LANConnection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Temporary injected handshake interruption"])
            }
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

    func releaseResume() {
        guard let (events, continuation) = heldResume else { return }
        heldResume = nil
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
