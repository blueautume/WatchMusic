import Foundation

/// Real PhoneLibrary file mutations in a standalone simulator process. Only
/// UUID-scoped fixture directories are changed; the transfer index is restored
/// byte-for-byte before the process exits. No player or transfer is started.
@main
struct PhoneBulkIntegrationProbe {
    @MainActor private static var assertions = 0

    @MainActor
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ProbeError.failure(message) }
        assertions += 1
    }

    @MainActor
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2, UUID(uuidString: arguments[1]) != nil else {
                throw ProbeError.failure("Usage: PhoneBulkIntegrationProbe FIXTURE_MP3 SIMULATOR_UDID")
            }
            try run(fixture: URL(fileURLWithPath: arguments[0]), simulatorID: arguments[1])
            print("PASS: \(assertions) native phone bulk integration assertions")
            // Keep asynchronous WC activation and duration tasks from running
            // after our synchronous, main-actor cleanup has restored the index.
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("PHONE_BULK_PROBE_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run(fixture: URL, simulatorID: String) throws {
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard documents.standardizedFileURL.path.contains("/CoreSimulator/Devices/\(simulatorID)/data/") else {
            throw ProbeError.failure("Refusing file mutations outside the requested simulator")
        }
        let fixtureBytes = try Data(contentsOf: fixture)
        try check(!fixtureBytes.isEmpty && fixture.pathExtension.lowercased() == "mp3", "fixture is a nonempty MP3")
        let musicRoot = documents.appendingPathComponent("Music", isDirectory: true)
        let defaultFolder = musicRoot.appendingPathComponent("默认目录", isDirectory: true)
        let index = documents.appendingPathComponent("transfers.json")
        let documentsExisted = manager.fileExists(atPath: documents.path)
        let musicExisted = manager.fileExists(atPath: musicRoot.path)
        let musicEntries = musicExisted ? Set(try manager.contentsOfDirectory(atPath: musicRoot.path)) : Set<String>()
        let defaultExisted = manager.fileExists(atPath: defaultFolder.path)
        let indexExisted = manager.fileExists(atPath: index.path)
        let indexBytes = indexExisted ? try Data(contentsOf: index) : nil
        let prefix = "BulkProbe-" + UUID().uuidString
        let sourceName = prefix + "-Source"
        let targetName = prefix + "-Target"
        let source = musicRoot.appendingPathComponent(sourceName, isDirectory: true)
        let target = musicRoot.appendingPathComponent(targetName, isDirectory: true)
        var library: PhoneLibrary?

        let outcome = Result<Void, Error> {
            library = PhoneLibrary()
            guard let library else { throw ProbeError.failure("PhoneLibrary initialization") }
            try check(library.errorMessage == nil, "real PhoneLibrary opens the simulator music root")
            try manager.createDirectory(at: source, withIntermediateDirectories: false)
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            let a = source.appendingPathComponent("A.mp3")
            let b = source.appendingPathComponent("B.mp3")
            let targetA = target.appendingPathComponent("A.mp3")
            let targetB = target.appendingPathComponent("B.mp3")
            try fixtureBytes.write(to: a)
            try fixtureBytes.write(to: b)
            let existingTarget = fixtureBytes + Data("existing-target-marker".utf8)
            try existingTarget.write(to: targetA)
            library.refreshFolders()
            let sourceFolder = PhoneFolder(name: sourceName)
            let targetFolder = PhoneFolder(name: targetName)
            guard let aTrack = library.tracks(in: sourceFolder).first(where: { $0.url == a }),
                  let bTrack = library.tracks(in: sourceFolder).first(where: { $0.url == b }) else {
                throw ProbeError.failure("fixture indexing through real PhoneLibrary")
            }
            try check(library.tracks(in: sourceFolder).count == 2, "real refresh indexes both fixture songs")

            let moved = library.moveTracks([aTrack, bTrack, aTrack], to: targetFolder)
            try check(moved == [b], "partial move returns only the successful original URL and de-duplicates A")
            try check(manager.fileExists(atPath: a.path), "collision leaves source A intact")
            try check(try Data(contentsOf: a) == fixtureBytes, "a failed move preserves the source audio bytes")
            try check(!manager.fileExists(atPath: b.path), "successful move removes original B")
            try check(try Data(contentsOf: targetA) == existingTarget, "existing destination A is never overwritten")
            try check(try Data(contentsOf: targetB) == fixtureBytes, "destination B exactly matches the MP3 fixture")
            try check(library.errorMessage?.contains("1 项") == true && library.errorMessage?.contains("A") == true,
                      "the duplicate collision is aggregated once while B still succeeds")
            guard let movedB = library.tracks(in: targetFolder).first(where: { $0.url == targetB }) else {
                throw ProbeError.failure("successful move refreshes the real library index")
            }
            try check(library.moveTracks([movedB, movedB], to: targetFolder).isEmpty, "same-folder move is a no-op")
            try check(library.errorMessage == nil, "a valid no-op clears the preceding batch warning")
            try check(try Data(contentsOf: targetB) == fixtureBytes, "same-folder move preserves audio bytes")

            let absentFolder = PhoneFolder(name: prefix + "-MissingFolder")
            try check(library.moveTracks([aTrack], to: absentFolder).isEmpty, "missing destination directory cannot report success")
            try check(library.errorMessage?.contains("目标目录") == true, "missing destination reports one useful error")
            try check(manager.fileExists(atPath: a.path), "missing destination leaves the source in place")
            let missing = PhoneTrack(folder: sourceName, fileName: "Missing.mp3", url: source.appendingPathComponent("Missing.mp3"))
            try check(library.moveTracks([missing], to: targetFolder).isEmpty, "missing source move fails without success URLs")
            try check(library.errorMessage != nil, "missing source move reports an aggregate error")
            try check(!manager.fileExists(atPath: target.appendingPathComponent("Missing.mp3").path),
                      "missing source move creates no destination placeholder")

            let deleted = library.deleteTracks([missing, aTrack, aTrack])
            try check(deleted == [a], "partial delete returns A once despite a missing source and duplicate selection")
            try check(!manager.fileExists(atPath: a.path), "successful delete removes only source A")
            try check(try Data(contentsOf: targetA) == existingTarget, "source deletion leaves same-name target A intact")
            try check(try Data(contentsOf: targetB) == fixtureBytes, "partial delete leaves unselected target B intact")
            try check(library.errorMessage?.contains("1 项") == true && library.errorMessage?.contains("Missing") == true,
                      "partial delete aggregates the failed source without hiding the successful deletion")
            let staleSourceURLs = Set(moved + deleted)
            let queue = [a, b, targetB].filter { !staleSourceURLs.contains($0) }
            try check(queue == [targetB], "returned original URLs remove stale queue entries and preserve moved destinations")

            try check(library.deleteTracks([movedB, movedB]) == [targetB], "duplicate delete of an existing song succeeds exactly once")
            try check(!manager.fileExists(atPath: targetB.path), "the selected target B is actually deleted")
            try check(library.errorMessage == nil, "fully successful delete clears previous aggregate errors")
            try check(try Data(contentsOf: targetA) == existingTarget, "all operations preserve the colliding unselected target A")
        }

        // No async main-actor task has run during the synchronous mutation block.
        library = nil
        var cleanupErrors: [String] = []
        for directory in [source, target] where manager.fileExists(atPath: directory.path) {
            do { try manager.removeItem(at: directory) }
            catch { cleanupErrors.append("fixture directory cleanup: \(error.localizedDescription)") }
        }
        do {
            if let indexBytes { try indexBytes.write(to: index, options: .atomic) }
            else if manager.fileExists(atPath: index.path) { try manager.removeItem(at: index) }
        } catch { cleanupErrors.append("transfer index restoration: \(error.localizedDescription)") }
        for (directory, existed) in [(defaultFolder, defaultExisted), (musicRoot, musicExisted), (documents, documentsExisted)] where !existed {
            do {
                if manager.fileExists(atPath: directory.path), try manager.contentsOfDirectory(atPath: directory.path).isEmpty {
                    try manager.removeItem(at: directory)
                }
            } catch { cleanupErrors.append("empty initialization directory cleanup: \(error.localizedDescription)") }
        }
        if !cleanupErrors.isEmpty { throw ProbeError.failure(cleanupErrors.joined(separator: "\n")) }
        try check(!manager.fileExists(atPath: source.path) && !manager.fileExists(atPath: target.path), "all UUID-scoped fixture directories are removed")
        if musicExisted {
            try check(Set(try manager.contentsOfDirectory(atPath: musicRoot.path)) == musicEntries, "preexisting music-root entries are preserved")
        } else {
            try check(!manager.fileExists(atPath: musicRoot.path), "a newly initialized empty music root is cleaned up")
        }
        if let indexBytes {
            try check(try Data(contentsOf: index) == indexBytes, "preexisting transfer index bytes are restored exactly")
        } else {
            try check(!manager.fileExists(atPath: index.path), "a previously absent transfer index stays absent")
        }
        try outcome.get()
    }

    private enum ProbeError: LocalizedError {
        case failure(String)
        var errorDescription: String? { if case .failure(let message) = self { return message }; return nil }
    }
}
