import CryptoKit
import Foundation

/// Only complete HTTP ranges enter this cache. Its committed byte count is the
/// crash-safe boundary; an interrupted append is truncated before being reused.
final class LANPartialDownloadStore {
    static let chunkSize: Int64 = 4 * 1_024 * 1_024
    private struct Entry: Codable {
        let identity: Identity
        let name: String
        var byteCount: Int64
        var updatedAt: Date
    }
    private struct Identity: Codable, Equatable {
        let path: String
        let byteCount: Int64
        let sha256: String
        init(_ file: LANTransferFile) {
            path = (file.folder + "/" + file.fileName).precomposedStringWithCanonicalMapping.lowercased()
            byteCount = file.byteCount
            sha256 = file.sha256.lowercased()
        }
        var key: String {
            let data = Data((path + "\n" + String(byteCount) + "\n" + sha256).utf8)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Checkpoint { let url: URL; let byteCount: Int64 }
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var entries: [String: Entry] = [:]
    private var loaded = false

    init(root: URL) { self.root = root }

    static func validResponse(_ response: HTTPURLResponse, offset: Int64, length: Int64, total: Int64) -> Bool {
        guard offset >= 0, length > 0, length <= total, offset <= total - length else { return false }
        if response.statusCode == 200 { return offset == 0 && length == total }
        guard response.statusCode == 206, let value = response.value(forHTTPHeaderField: "Content-Range") else { return false }
        let fields = value.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return false }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        func number(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(text)
        }
        guard bounds.count == 2, let start = number(bounds[0]), let end = number(bounds[1]),
              let size = number(parts[1]), size == total, start >= offset,
              start <= end, end == offset + length - 1 else { return false }
        // A daemon-retried request can report only its final subrange. The
        // caller additionally verifies the assembled temporary file's length.
        return true
    }

    func checkpoint(for file: LANTransferFile) throws -> Checkpoint? {
        try load()
        let identity = Identity(file)
        guard let entry = entries[identity.key] else { return nil }
        let url = root.appendingPathComponent(entry.name)
        guard entry.identity == identity, Self.safeName(entry.name), entry.byteCount > 0,
              entry.byteCount <= file.byteCount,
              Date().timeIntervalSince(entry.updatedAt) < 7 * 24 * 3_600 else {
            try remove(file); return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              let size = attributes?[.size] as? NSNumber, size.int64Value >= entry.byteCount else {
            try remove(file); return nil
        }
        if size.int64Value != entry.byteCount {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(entry.byteCount))
            try handle.synchronize()
        }
        return Checkpoint(url: url, byteCount: entry.byteCount)
    }

    /// Called only after the response range, final endpoint, and chunk length
    /// have been validated. It never holds more than 64 KiB of file data.
    func append(_ chunk: URL, for file: LANTransferFile, offset: Int64, length: Int64) throws -> Checkpoint {
        try load()
        guard offset >= 0, length > 0, offset <= file.byteCount - length,
              let size = try FileManager.default.attributesOfItem(atPath: chunk.path)[.size] as? NSNumber,
              size.int64Value == length else { throw invalid() }
        let identity = Identity(file)
        let prefix = try checkpoint(for: file)
        let name: String
        let destination: URL
        if offset == 0 {
            try remove(file)
            name = UUID().uuidString + ".partial"
            destination = root.appendingPathComponent(name)
            try FileManager.default.moveItem(at: chunk, to: destination)
            protect(destination)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.synchronize()
        } else {
            guard let prefix, prefix.byteCount == offset else { throw invalid() }
            name = prefix.url.lastPathComponent
            destination = prefix.url
            let input = try FileHandle(forReadingFrom: chunk)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.seek(toOffset: UInt64(offset))
            var remaining = length
            while remaining > 0 {
                let written = try autoreleasepool { () throws -> Int in
                    guard let data = try input.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else { throw invalid() }
                    try output.write(contentsOf: data)
                    return data.count
                }
                remaining -= Int64(written)
            }
            try output.synchronize()
        }
        entries[identity.key] = Entry(identity: identity, name: name, byteCount: offset + length, updatedAt: Date())
        try prune(keeping: identity.key)
        try persist()
        return Checkpoint(url: destination, byteCount: offset + length)
    }

    /// Detach a completed prefix after moving it to the validation directory.
    func forget(_ file: LANTransferFile) throws {
        try load()
        entries.removeValue(forKey: Identity(file).key)
        try persist()
    }

    func remove(_ file: LANTransferFile) throws {
        try load()
        if let entry = entries.removeValue(forKey: Identity(file).key), Self.safeName(entry.name) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.name))
        }
        try persist()
    }

    private func load() throws {
        guard !loaded else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            guard try manager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else { throw invalid() }
        } else { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
        protect(root)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var directory = root; try? directory.setResourceValues(values)
        if let attributes = try? manager.attributesOfItem(atPath: indexURL.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max <= 2_097_152,
           let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded.filter {
                $0.key == $0.value.identity.key && Self.safeName($0.value.name) &&
                $0.value.byteCount > 0 && $0.value.byteCount <= $0.value.identity.byteCount &&
                $0.value.identity.byteCount <= 8 * 1_024 * 1_024 * 1_024
            }
        }
        loaded = true
    }

    private func prune(keeping key: String) throws {
        // Bound abandoned files without ever discarding the active prefix.
        var total = entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
        for (other, entry) in entries.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }) where other != key {
            if entries.count <= 16, total <= 8 * 1_024 * 1_024 * 1_024,
               Date().timeIntervalSince(entry.updatedAt) < 7 * 24 * 3_600 { continue }
            entries.removeValue(forKey: other)
            total -= entry.byteCount
            if Self.safeName(entry.name) { try? FileManager.default.removeItem(at: root.appendingPathComponent(entry.name)) }
        }
        let referenced = Set(entries.values.map(\.name))
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where Self.safeName(url.lastPathComponent) && !referenced.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
        protect(indexURL)
    }
    private static func safeName(_ name: String) -> Bool {
        name.hasSuffix(".partial") && UUID(uuidString: String(name.dropLast(8))) != nil
    }
    private func protect(_ url: URL) {
        #if os(iOS) || os(watchOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    private func invalid() -> NSError {
        NSError(domain: "LANPartialDownloadStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "局域网断点数据无效，请重试。"])
    }
}
