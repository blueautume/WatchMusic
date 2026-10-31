import AVFoundation
import Foundation

/// File-provider reads and audio validation run off the main actor.
enum PhoneResourceImport {
    static func audio(_ source: URL, into directory: URL, cancellation: PhoneImportCancellation? = nil) throws -> URL {
        try checkCancellation(cancellation)
        guard let format = AudioFileFormat.format(for: source) else { throw importError(L10n.text("仅支持 MP3 或 FLAC 音频")) }
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString).\(format.rawValue)")
        defer { try? manager.removeItem(at: staging) }
        try withCoordinatedURL(source, cancellation: cancellation) { coordinated in
            try checkCancellation(cancellation)
            let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw importError(L10n.text("音频文件为空或不可读取")) }
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard available > Int64(values.fileSize ?? 0) + 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
            guard manager.createFile(atPath: staging.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let input = try FileHandle(forReadingFrom: coordinated)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            while true {
                try checkCancellation(cancellation)
                let copied = try autoreleasepool { () throws -> Bool in
                    guard let data = try input.read(upToCount: 65_536), !data.isEmpty else { return false }
                    try checkCancellation(cancellation)
                    try output.write(contentsOf: data)
                    return true
                }
                if !copied { break }
            }
        }
        try checkCancellation(cancellation)
        let probe = try AVAudioPlayer(contentsOf: staging)
        guard probe.duration.isFinite, probe.duration > 0 else { throw importError(L10n.text("音频无法解码")) }
        var stem = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasPrefix(".") { stem.removeFirst() }
        if stem.isEmpty { stem = L10n.text("未命名歌曲") }
        while stem.utf8.count > 170 { stem.removeLast() }
        var destination = directory.appendingPathComponent(AudioFileFormat.fileName(stem: stem, format: format))
        var suffix = 2
        while manager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(AudioFileFormat.fileName(stem: stem, format: format, duplicateIndex: suffix))
            suffix += 1
        }
        try checkCancellation(cancellation)
        try manager.moveItem(at: staging, to: destination)
        return destination
    }

    private static func withCoordinatedURL<T>(_ source: URL, cancellation: PhoneImportCancellation?, perform: (URL) throws -> T) throws -> T {
        try checkCancellation(cancellation)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator()
        cancellation?.setCoordinator(coordinator)
        defer { cancellation?.setCoordinator(nil) }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result { try perform(url) }
        }
        try checkCancellation(cancellation)
        if let coordinationError { throw coordinationError }
        guard let result else { throw importError(L10n.text("无法协调读取所选文件")) }
        return try result.get()
    }

    private static func checkCancellation(_ cancellation: PhoneImportCancellation?) throws {
        try Task.checkCancellation()
        try cancellation?.checkCancellation()
    }

    static func importError(_ message: String) -> NSError {
        NSError(domain: "PhoneResourceImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Also cancels a file-provider coordination that has not entered its accessor
/// yet. Cooperative Task cancellation alone cannot stop that system operation.
final class PhoneImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?

    func cancel() {
        lock.lock()
        cancelled = true
        let current = coordinator
        lock.unlock()
        current?.cancel()
    }

    func setCoordinator(_ value: NSFileCoordinator?) {
        lock.lock()
        coordinator = value
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { value?.cancel() }
    }

    func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}
