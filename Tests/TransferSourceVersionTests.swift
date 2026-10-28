import Darwin
import Foundation

@main
struct TransferSourceVersionTests {
    static var assertions = 0

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw TestFailure.failed(message) }
        assertions += 1
    }

    static func rejected(_ url: URL, _ message: String) throws {
        do { _ = try TransferSourceVersion.read(url) }
        catch { assertions += 1; return }
        throw TestFailure.failed(message)
    }

    static func preserveModificationTime(_ version: TransferSourceVersion, at url: URL) throws {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(version.modificationSeconds), tv_nsec: Int(version.modificationNanoseconds))]
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return utimensat(AT_FDCWD, path, &times, 0)
        }
        guard result == 0 else { throw TestFailure.failed("Cannot restore fixture mtime") }
    }

    static func run() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TransferSourceVersionTests-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.flac")
        try Data(repeating: 0x21, count: 32).write(to: source)
        let first = try TransferSourceVersion.read(source)
        try expect(first.byteCount == 32, "Version records the actual file length")
        try expect(first.inode != 0, "Version records a real file identity")
        try expect((0..<1_000_000_000).contains(first.modificationNanoseconds), "Modification time retains valid nanoseconds")
        try expect((0..<1_000_000_000).contains(first.changeNanoseconds), "Change time retains valid nanoseconds")
        try expect(TransferSourceVersion.read(source) == first, "Unchanged file reads return the same uncached version")
        let encoded = try JSONEncoder().encode(first)
        try expect(JSONDecoder().decode(TransferSourceVersion.self, from: encoded) == first, "All identity and timestamp fields survive Codable round trip")

        let empty = root.appendingPathComponent("empty.mp3")
        try Data().write(to: empty)
        try expect(TransferSourceVersion.read(empty).byteCount == 0, "A regular empty file has a version; send eligibility decides whether it is audio")
        try rejected(root.appendingPathComponent("missing.flac"), "A missing file cannot reuse a cached version")
        try rejected(root, "A directory is not a regular source")
        try rejected(URL(string: "https://example.invalid/fixture.flac")!, "A remote URL cannot be treated as a local path")
        let link = root.appendingPathComponent("link.flac")
        try manager.createSymbolicLink(at: link, withDestinationURL: source)
        try rejected(link, "A symbolic link cannot supply the target's version")

        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x22, count: 32))
        try handle.close()
        let appended = try TransferSourceVersion.read(source)
        try expect(appended.byteCount == 64 && appended != first, "Appending invalidates a prior digest cache")
        try expect(appended.inode == first.inode && appended.deviceID == first.deviceID, "An in-place append retains its identity")

        // Preserve both length and mtime deliberately: ctime must still detect
        // this content change instead of accepting an apparently identical file.
        Thread.sleep(forTimeInterval: 0.02)
        let writer = try FileHandle(forWritingTo: source)
        try writer.write(contentsOf: Data(repeating: 0x33, count: 64))
        try writer.close()
        try preserveModificationTime(appended, at: source)
        let rewritten = try TransferSourceVersion.read(source)
        try expect(rewritten.byteCount == appended.byteCount && rewritten.inode == appended.inode,
                   "Same-size in-place replacement retains size and identity")
        try expect(rewritten.modificationSeconds == appended.modificationSeconds && rewritten.modificationNanoseconds == appended.modificationNanoseconds,
                   "The regression fixture actually restores the complete original mtime")
        try expect(rewritten.changeSeconds != appended.changeSeconds || rewritten.changeNanoseconds != appended.changeNanoseconds,
                   "Change time detects a same-size write even after mtime restoration")
        try expect(rewritten != appended, "A restored mtime never makes a rewritten file equal to its cached version")

        let replacement = root.appendingPathComponent("replacement.flac")
        try Data(repeating: 0x44, count: 64).write(to: replacement)
        try preserveModificationTime(rewritten, at: replacement)
        let replacementVersion = try TransferSourceVersion.read(replacement)
        try expect(replacementVersion.inode != rewritten.inode, "Atomic replacement fixture has a distinct inode")
        let replaced = replacement.withUnsafeFileSystemRepresentation { from in
            source.withUnsafeFileSystemRepresentation { to in Darwin.rename(from!, to!) }
        }
        try expect(replaced == 0, "Fixture atomically replaces the existing path")
        let final = try TransferSourceVersion.read(source)
        try expect(final.byteCount == rewritten.byteCount && final.modificationSeconds == rewritten.modificationSeconds && final.modificationNanoseconds == rewritten.modificationNanoseconds,
                   "Atomic replacement preserves the old size and mtime for the regression")
        try expect(final.inode == replacementVersion.inode && final.inode != rewritten.inode && final != rewritten,
                   "File identity invalidates a same-size, same-mtime atomic replacement")
        try expect(Data(contentsOf: source) == Data(repeating: 0x44, count: 64), "Replacement changed the real file bytes")

        try manager.removeItem(at: source)
        try rejected(source, "Deleting a previously observed source invalidates it immediately")
        print("PASS: \(assertions) transfer source version assertions")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("TRANSFER_SOURCE_VERSION_TEST_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    enum TestFailure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
