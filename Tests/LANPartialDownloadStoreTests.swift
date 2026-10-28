import Foundation

@main struct LANPartialDownloadStoreTests {
    static var count = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        count += 1
        if try !condition() { throw NSError(domain: "LANPartialTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func file(id: String = UUID().uuidString, folder: String = "音乐", name: String = "测试.flac", size: Int64 = 12,
                     sha: String = String(repeating: "a", count: 64)) -> LANTransferFile {
        LANTransferFile(id: id, folder: folder, fileName: name, byteCount: size, sha256: sha)
    }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("LANPartialTests-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("Cache")
        var store = LANPartialDownloadStore(root: storeRoot)
        let song = file()
        try expect(try store.checkpoint(for: song) == nil, "new song has no checkpoint")
        func chunk(_ bytes: [UInt8]) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString)
            try Data(bytes).write(to: url)
            return url
        }
        let first = try store.append(chunk([0, 1, 2, 3]), for: song, offset: 0, length: 4)
        try expect(first.byteCount == 4, "first complete response commits a prefix")
        try expect(try Data(contentsOf: first.url) == Data([0, 1, 2, 3]), "committed prefix retains actual received bytes")
        store = LANPartialDownloadStore(root: storeRoot)
        try expect(try store.checkpoint(for: file())?.byteCount == 4, "new file and session UUIDs reuse the same content fingerprint")
        try expect(try store.checkpoint(for: file(folder: "另一目录")) == nil, "different destination cannot reuse a checkpoint")
        try expect(try store.checkpoint(for: file(sha: String(repeating: "b", count: 64))) == nil, "changed content cannot reuse a checkpoint")
        try expect(try store.checkpoint(for: file(size: 13)) == nil, "changed size cannot reuse a checkpoint")
        // Simulate a process dying after an append but before index commit.
        let handle = try FileHandle(forWritingTo: first.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([99, 99, 99])); try handle.close()
        store = LANPartialDownloadStore(root: storeRoot)
        let recovered = try store.checkpoint(for: song)!
        try expect(recovered.byteCount == 4, "crash recovery uses only the journaled boundary")
        try expect(try Data(contentsOf: recovered.url) == Data([0, 1, 2, 3]), "uncommitted tail is truncated before reuse")
        let second = try store.append(chunk([4, 5, 6, 7]), for: song, offset: 4, length: 4)
        try expect(second.byteCount == 8, "next range advances the committed boundary")
        try expect(try Data(contentsOf: second.url) == Data(0...7), "ranges assemble in exact order")
        do {
            _ = try store.append(chunk([8, 9]), for: song, offset: 7, length: 2)
            throw NSError(domain: "LANPartialTests", code: 2)
        } catch { try expect((error as NSError).domain == "LANPartialDownloadStore", "overlap is rejected") }
        do {
            _ = try store.append(chunk([8]), for: song, offset: 8, length: 2)
            throw NSError(domain: "LANPartialTests", code: 2)
        } catch { try expect((error as NSError).domain == "LANPartialDownloadStore", "short chunks never enter the committed prefix") }
        let complete = try store.append(chunk([8, 9, 10, 11]), for: song, offset: 8, length: 4)
        try expect(complete.byteCount == 12, "final chunk forms a complete candidate for independent SHA validation")
        try expect(try Data(contentsOf: complete.url) == Data(0...11), "complete candidate has exact original content")
        let validation = root.appendingPathComponent("complete.download")
        try manager.moveItem(at: complete.url, to: validation)
        try store.forget(song)
        try expect(try store.checkpoint(for: song) == nil, "validation handoff detaches the old checkpoint")
        _ = try store.append(chunk([0, 1]), for: song, offset: 0, length: 2)
        let removable = try store.checkpoint(for: song)!.url
        try store.remove(song)
        try expect(!manager.fileExists(atPath: removable.path), "explicit cancellation removes cached bytes")
        try expect(try LANPartialDownloadStore(root: storeRoot).checkpoint(for: song) == nil, "cancellation remains cleared after process restart")
        _ = try store.append(chunk([0, 1]), for: song, offset: 0, length: 2)
        let symlink = try store.checkpoint(for: song)!.url
        try manager.removeItem(at: symlink)
        try manager.createSymbolicLink(at: symlink, withDestinationURL: validation)
        try expect(try store.checkpoint(for: song) == nil, "a cache symlink is rejected")
        try expect(try Data(contentsOf: validation) == Data(0...11), "rejecting a symlink does not modify its target")

        func response(_ status: Int, _ range: String? = nil) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://127.0.0.1:1234/v1/files/test")!, statusCode: status,
                            httpVersion: "HTTP/1.1", headerFields: range.map { ["Content-Range": $0] })!
        }
        try expect(LANPartialDownloadStore.validResponse(response(206, "bytes 4-7/12"), offset: 4, length: 4, total: 12), "exact requested range accepted")
        try expect(LANPartialDownloadStore.validResponse(response(206, "bytes 6-7/12"), offset: 4, length: 4, total: 12), "daemon-assembled continuation accepted subject to complete temporary length check")
        try expect(!LANPartialDownloadStore.validResponse(response(206, "bytes 3-7/12"), offset: 4, length: 4, total: 12), "range cannot overlap earlier committed prefix")
        try expect(!LANPartialDownloadStore.validResponse(response(206, "bytes 4-8/12"), offset: 4, length: 4, total: 12), "wrong range end rejected")
        try expect(!LANPartialDownloadStore.validResponse(response(206, "bytes 4-7/13"), offset: 4, length: 4, total: 12), "wrong full content size rejected")
        try expect(!LANPartialDownloadStore.validResponse(response(200), offset: 4, length: 4, total: 12), "full response cannot be appended to a partial prefix")
        try expect(!LANPartialDownloadStore.validResponse(response(200), offset: 0, length: 4, total: 12), "server ignoring a bounded range cannot overfill the cache")
        try expect(LANPartialDownloadStore.validResponse(response(200), offset: 0, length: 12, total: 12), "small complete file permits normal HTTP 200")
        print("PASS: \(count) LAN partial download store assertions")
    }
}
