import Foundation

/// A derived cache, independent of phone task history. Every hit is bound to a
/// fresh filesystem version; legacy files are hashed once with bounded memory.
final class LANInventory: @unchecked Sendable {
    private struct Entry: Codable {
        let version: TransferSourceVersion
        let sha256: String
        let checkedAt: Date
    }

    private let root: URL
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "com.offlinewatchplayer.lab.inventory", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let manager = FileManager.default
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private let maximumEntries = 5_000
    private let maximumCacheBytes = 8 * 1_024 * 1_024

    init(rootURL: URL, cacheURL: URL? = nil) {
        root = rootURL.standardizedFileURL
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LANInventory-v1", isDirectory: true).appendingPathComponent("fingerprints.json")
    }

    func matching(_ request: LANInventoryRequest,
                  completion: @escaping (Result<LANInventoryReply, Error>) -> Void) {
        queue.async { [self] in
            let result = Result {
                try LANInventoryWire.validate(request)
                loadIfNeeded()
                var matches: [String] = []
                var changed = false
                defer { if changed { persist() } }
                for file in request.files {
                    let key = LANInventoryWire.pathKey(folder: file.folder, fileName: file.fileName)
                    guard let url = try libraryURL(for: file) else {
                        changed = entries.removeValue(forKey: key) != nil || changed
                        continue
                    }
                    let before = try TransferSourceVersion.read(url)
                    guard before.byteCount == file.byteCount else {
                        changed = entries.removeValue(forKey: key) != nil || changed
                        continue
                    }
                    let digest: String
                    if let cached = entries[key], cached.version == before,
                       LANInventoryWire.validDigest(cached.sha256) {
                        digest = cached.sha256
                    } else {
                        digest = try LANFileDigest.sha256(of: url)
                        let after = try TransferSourceVersion.read(url)
                        guard before == after, try libraryURL(for: file) == url else {
                            entries.removeValue(forKey: key); changed = true
                            throw libraryChanged()
                        }
                        entries[key] = Entry(version: after, sha256: digest, checkedAt: Date())
                        changed = true
                    }
                    // A file can be replaced while a cached comparison runs.
                    guard try TransferSourceVersion.read(url) == before,
                          try libraryURL(for: file) == url else { throw libraryChanged() }
                    if digest.lowercased() == file.sha256.lowercased() { matches.append(file.id) }
                }
                return LANInventoryReply(requestID: request.requestID, matchedFileIDs: matches)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Called synchronously on the library's storage queue after the verified
    /// atomic commit. Capture its version now, before another write can replace
    /// the path; never bind the old digest to a later asynchronously read file.
    func recordValidated(_ file: LANTransferFile) {
        guard LANInventoryWire.validDigest(file.sha256),
              let url = try? libraryURL(for: file),
              let version = try? TransferSourceVersion.read(url), version.byteCount == file.byteCount else { return }
        queue.async { [self] in
            guard (try? libraryURL(for: file)) == url,
                  (try? TransferSourceVersion.read(url)) == version else { return }
            loadIfNeeded()
            entries[LANInventoryWire.pathKey(folder: file.folder, fileName: file.fileName)] =
                Entry(version: version, sha256: file.sha256.lowercased(), checkedAt: Date())
            persist()
        }
    }

    private func libraryURL(for file: LANTransferFile) throws -> URL? {
        guard LANTransferValidation.isSafeComponent(file.folder),
              LANTransferValidation.isSafeComponent(file.fileName) else { return nil }
        let folder = root.appendingPathComponent(file.folder, isDirectory: true)
        let url = folder.appendingPathComponent(file.fileName)
        guard try isDirectory(root), try isDirectory(folder) else { return nil }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalFolder.deletingLastPathComponent() == canonicalRoot,
              url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == canonicalFolder else { return nil }
        do { _ = try TransferSourceVersion.read(url); return url }
        catch {
            if isMissing(error) { return nil }
            // Symlinks and nonregular entries are never treated as saved songs.
            let values = try? manager.attributesOfItem(atPath: url.path)
            if values?[.type] as? FileAttributeType != .typeRegular { return nil }
            throw error
        }
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        do { return try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory }
        catch { if isMissing(error) { return false }; throw error }
    }

    private func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ||
            error.domain == NSPOSIXErrorDomain && (error.code == 2 || error.code == 20)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let size = (try? manager.attributesOfItem(atPath: cacheURL.path)[.size]) as? NSNumber,
              size.intValue <= maximumCacheBytes,
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data),
              decoded.count <= maximumEntries else { return }
        entries = decoded.filter { LANInventoryWire.validDigest($0.value.sha256) }
    }

    private func persist() {
        if entries.count > maximumEntries {
            let expired = entries.sorted { $0.value.checkedAt < $1.value.checkedAt }
                .prefix(entries.count - maximumEntries).map(\.key)
            expired.forEach { entries.removeValue(forKey: $0) }
        }
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var protectedDirectory = directory
            try? protectedDirectory.setResourceValues(resourceValues)
            let data = try JSONEncoder().encode(entries)
            guard data.count <= maximumCacheBytes else { return }
            try data.write(to: cacheURL, options: .atomic)
            #if os(iOS) || os(watchOS)
            try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: cacheURL.path)
            #endif
        } catch { /* A derived cache failure must not fail a completed save. */ }
    }

    private func libraryChanged() -> NSError {
        NSError(domain: "LANInventory", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "手表音乐库发生变化，请重试。"])
    }
}
