import Foundation
import WatchConnectivity

/// Exercises the real phone model in its explicit, in-memory simulator mode.
/// Native transport pause is verified separately by run-watch-lan-probe.py.
@main
struct PhoneTransferControlProbe {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError(message) }
    }

    @MainActor static func main() async {
        guard CommandLine.arguments.contains("-preview-transfers-in-progress") else { fatalError("Explicit isolated preview mode is required") }
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard documents.path.contains("/CoreSimulator/Devices/") else { fatalError("Simulator only") }
        let index = documents.appendingPathComponent("transfers.json")
        let music = documents.appendingPathComponent("Music")
        let indexBefore = try? Data(contentsOf: index)
        let musicBefore = try? manager.contentsOfDirectory(atPath: music.path)
        let library = PhoneLibrary()
        library.prepareTransferListPreviewIfRequested()
        check(library.activeTransfers.count == 5 && library.storedTransfers.count == 2, "Preview seeds expected isolated records")
        let activeID = "preview-active"
        check(library.canToggleTransfers(ids: [activeID]) && !library.shouldStartTransfers(ids: [activeID]), "Active selection offers pause")
        library.pauseTransfers(ids: [activeID])
        check(library.transfers.first { $0.id == activeID }?.state == .paused, "Pause updates only the selected task")
        check(library.transfers.first { $0.id == "preview-waiting-old" }?.state == .queued, "Other queued work is unaffected by selected pause")
        check(library.progress[activeID] == 0.35, "Paused progress fraction is preserved")
        check(library.transferMetrics[activeID]?.completedBytes == 6_300_000, "Paused byte count is preserved")
        check(library.transferMetrics[activeID]?.bytesPerSecond == nil && library.transferMetrics[activeID]?.estimatedTimeRemaining == nil,
              "Paused work does not report speed or an ETA")
        check(library.shouldStartTransfers(ids: [activeID]), "Paused selection offers start")
        library.resumeTransfers(ids: [activeID])
        check(library.transfers.first { $0.id == activeID }?.state == .queued, "Start releases selected paused state")
        check(library.progress[activeID] == 0.35, "Start retains partial progress")

        var completions = 0
        library.send([]) { ids in completions += 1; check(ids.isEmpty, "Empty send reports no queued identities") }
        check(completions == 1, "Empty-send completion runs once")
        let unavailable = PhoneTrack(folder: "no", fileName: "no.mp3", url: URL(fileURLWithPath: "/missing/no.mp3"))
        library.send([unavailable]) { ids in completions += 1; check(ids.isEmpty, "Unavailable connection reports no queued identities") }
        check(completions == 2, "Rejected send also completes once instead of hanging selection UI")

        library.clearTransfers(ids: [activeID])
        check(!library.transfers.contains { $0.id == activeID }, "Clear removes the selected pending record")
        check(library.activeTransfers.count == 4, "Clear preserves other pending and retryable records")
        let beforeLate = library.transfers.map(\.id)
        let late = LANTransferEvent(sessionID: UUID().uuidString, fileID: activeID, kind: .stored,
                                    completedBytes: 18_000_000, totalBytes: 18_000_000, message: "saved")
        if let message = try? LANTransferWire.message(late, type: LANTransferWire.eventType) {
            library.session(WCSession.default, didReceiveMessage: message)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        check(library.transfers.map(\.id) == beforeLate, "A late save event cannot recreate a cleared task")
        library.clearAllTasks()
        check(library.activeTransfers.isEmpty && library.transfers.allSatisfy { $0.state == .stored }, "Clear-all keeps successful history only")
        check(library.storedTransfers.count == 2, "Clear-all does not remove completed records")
        let savedID = library.storedTransfers[0].id
        library.clearTransfers(ids: [savedID])
        check(library.storedTransfers.count == 1, "Completed selection clears only that history entry")
        check((try? Data(contentsOf: index)) == indexBefore, "Isolated control operations do not write the real transfer index")
        check((try? manager.contentsOfDirectory(atPath: music.path)) == musicBefore, "Isolated control operations do not create or remove music entries")
        print("PASS: \(assertions) phone transfer control model assertions")
        exit(0)
    }
}
