import Foundation

@main
struct LANInventoryTests {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.failed(message) }
        assertions += 1
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS: \(assertions) LAN inventory assertions") }
        catch { FileHandle.standardError.write(Data("LAN_INVENTORY_FAIL: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    @MainActor static func matching(_ inventory: LANInventory, _ files: [LANTransferFile]) async throws -> LANInventoryReply {
        try await withCheckedThrowingContinuation { continuation in
            inventory.matching(LANInventoryRequest(requestID: UUID().uuidString, files: files)) { continuation.resume(with: $0) }
        }
    }
    @MainActor static func run() async throws {
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent("LANInventoryTests-" + UUID().uuidString, isDirectory: true)
        let root = temp.appendingPathComponent("Music", isDirectory: true)
        let folder = root.appendingPathComponent("Test", isDirectory: true)
        let cache = temp.appendingPathComponent("Cache/fingerprints.json")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temp) }
        let url = folder.appendingPathComponent("Song.flac")
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let file = LANTransferFile(id: UUID().uuidString, folder: "Test", fileName: "Song.flac", byteCount: 3, sha256: abc)
        let inventory = LANInventory(rootURL: root, cacheURL: cache)
        try Data("abc".utf8).write(to: url)
        try check(try await matching(inventory, [file]).matchedFileIDs == [file.id], "Legacy file is detected by actual content")
        try check(manager.fileExists(atPath: cache.path), "Successful hash persists a derived cache")
        let restarted = LANInventory(rootURL: root, cacheURL: cache)
        try check(try await matching(restarted, [file]).matchedFileIDs == [file.id], "Inventory survives app restart independently of phone history")
        let wrong = LANTransferFile(id: UUID().uuidString, folder: file.folder, fileName: file.fileName, byteCount: 3, sha256: String(repeating: "0", count: 64))
        try check(try await matching(inventory, [wrong]).matchedFileIDs.isEmpty, "Same path and size do not substitute for matching content")
        let oldDate = try manager.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        let writer = try FileHandle(forWritingTo: url)
        try writer.write(contentsOf: Data("xyz".utf8)); try writer.close()
        try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        try check(try await matching(inventory, [file]).matchedFileIDs.isEmpty, "Same-size mutation with restored mtime invalidates a cached fingerprint")
        try manager.removeItem(at: url)
        try check(try await matching(inventory, [file]).matchedFileIDs.isEmpty, "Deleted watch file can be transferred again")
        try Data("abc".utf8).write(to: url)
        inventory.recordValidated(file)
        try check(try await matching(inventory, [file]).matchedFileIDs == [file.id], "Verified save records its fingerprint")
        let changed = try FileHandle(forWritingTo: url)
        try changed.write(contentsOf: Data("xyz".utf8)); try changed.close()
        try check(try await matching(inventory, [file]).matchedFileIDs.isEmpty, "Post-save replacement cannot keep an obsolete matching fingerprint")
        // Hold the serial cache queue with a real bounded-memory hash. A save
        // records abc now, but xyz replaces it before that queued record runs.
        let blockerURL = folder.appendingPathComponent("Blocker.flac")
        guard manager.createFile(atPath: blockerURL.path, contents: nil) else { throw Failure.failed("Could not create blocking fixture") }
        let blockerHandle = try FileHandle(forWritingTo: blockerURL)
        try blockerHandle.truncate(atOffset: 128 * 1_024 * 1_024); try blockerHandle.close()
        let blocker = LANTransferFile(id: UUID().uuidString, folder: "Test", fileName: "Blocker.flac", byteCount: 128 * 1_024 * 1_024, sha256: String(repeating: "0", count: 64))
        var blockerFinished = false
        inventory.matching(LANInventoryRequest(requestID: UUID().uuidString, files: [blocker])) { _ in blockerFinished = true }
        try Data("abc".utf8).write(to: url)
        inventory.recordValidated(file)
        let raceWriter = try FileHandle(forWritingTo: url)
        try raceWriter.write(contentsOf: Data("xyz".utf8)); try raceWriter.close()
        try check(try await matching(inventory, [file]).matchedFileIDs.isEmpty, "A delayed cache write cannot bind a prior save digest to a later replacement")
        try check(blockerFinished, "The concurrent hash completed before the queued replacement check")
        let missing = LANTransferFile(id: UUID().uuidString, folder: "Missing", fileName: "Song.flac", byteCount: 3, sha256: abc)
        try check(try await matching(inventory, [missing]).matchedFileIDs.isEmpty, "A missing directory does not fail the candidate batch")
        let outside = temp.appendingPathComponent("Outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("Outside.flac")
        try Data("abc".utf8).write(to: outsideFile)
        let linked = folder.appendingPathComponent("Link.flac")
        try manager.createSymbolicLink(at: linked, withDestinationURL: outsideFile)
        let linkFile = LANTransferFile(id: UUID().uuidString, folder: "Test", fileName: "Link.flac", byteCount: 3, sha256: abc)
        try check(try await matching(inventory, [linkFile]).matchedFileIDs.isEmpty, "A final symlink is not a saved library file")
        let linkedFolder = root.appendingPathComponent("Linked", isDirectory: true)
        try manager.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
        let folderLinkFile = LANTransferFile(id: UUID().uuidString, folder: "Linked", fileName: "Outside.flac", byteCount: 3, sha256: abc)
        try check(try await matching(inventory, [folderLinkFile]).matchedFileIDs.isEmpty, "A symlinked directory never exposes files outside the library")
        let linkedRoot = temp.appendingPathComponent("LinkedRoot", isDirectory: true)
        try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        try Data("abc".utf8).write(to: url)
        let badRoot = LANInventory(rootURL: linkedRoot, cacheURL: temp.appendingPathComponent("OtherCache/cache.json"))
        try check(try await matching(badRoot, [file]).matchedFileIDs.isEmpty, "A symlinked library root is rejected even for a matching regular song")
        var invalid = false
        do { _ = try await matching(inventory, [LANTransferFile(id: UUID().uuidString, folder: "..", fileName: "Song.flac", byteCount: 3, sha256: abc)]) }
        catch { invalid = true }
        try check(invalid, "Traversal candidates are rejected")
        let request = LANInventoryRequest(requestID: UUID().uuidString, files: [file])
        try LANInventoryWire.validate(request)
        let reply = LANInventoryReply(requestID: request.requestID, matchedFileIDs: [file.id])
        try LANInventoryWire.validate(reply, for: request)
        try check(true, "A correlated subset reply is accepted")
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        try check(rejects { try LANInventoryWire.validate(LANInventoryReply(requestID: UUID().uuidString, matchedFileIDs: [file.id]), for: request) }, "A reply cannot be reused for another request")
        try check(rejects { try LANInventoryWire.validate(LANInventoryReply(requestID: request.requestID, matchedFileIDs: [UUID().uuidString]), for: request) }, "Unknown matched identifiers are rejected")
        try check(rejects { try LANInventoryWire.validate(LANInventoryReply(requestID: request.requestID, matchedFileIDs: [file.id, file.id]), for: request) }, "Duplicate matches are rejected")
        try check(rejects { try LANInventoryWire.validate(LANInventoryRequest(requestID: request.requestID, files: [file, file])) }, "Duplicate request identifiers and paths are rejected")
        let caseAlias = LANTransferFile(id: UUID().uuidString, folder: "test", fileName: "song.flac", byteCount: 3, sha256: abc)
        try check(rejects { try LANInventoryWire.validate(LANInventoryRequest(requestID: request.requestID, files: [file, caseAlias])) }, "Case-equivalent destination paths are unique")
        try check(rejects { try LANInventoryWire.validate(LANInventoryRequest(requestID: request.requestID, files: [])) }, "Empty inventory requests are rejected")
        let ten = (0..<10).map { index in LANTransferFile(id: UUID().uuidString, folder: "F", fileName: "\(index).flac", byteCount: 3, sha256: abc) }
        try LANInventoryWire.validate(LANInventoryRequest(requestID: request.requestID, files: ten))
        try check(true, "Ten-file chunks are valid")
        try check(rejects { try LANInventoryWire.validate(LANInventoryRequest(requestID: request.requestID, files: ten + [file])) }, "Oversized inventory requests are rejected")
        let wire = try LANTransferWire.message(request, type: LANInventoryWire.requestType)
        let decoded = LANTransferWire.decode(LANInventoryRequest.self, from: wire, type: LANInventoryWire.requestType)
        try check(decoded?.files == request.files && decoded?.requestID == request.requestID, "Inventory wire round trip preserves only candidate fingerprints")
    }
    enum Failure: LocalizedError { case failed(String); var errorDescription: String? { if case .failed(let message) = self { return message }; return nil } }
}
