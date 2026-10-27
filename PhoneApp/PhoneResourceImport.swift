import AVFoundation
import Foundation

/// File-provider reads and audio validation run off the main actor.
enum PhoneResourceImport {
    static func audio(_ source: URL, into directory: URL) throws -> URL {
        guard let format = AudioFileFormat.format(for: source) else { throw importError("仅支持 MP3 或 FLAC 音频") }
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString).\(format.rawValue)")
        defer { try? manager.removeItem(at: staging) }
        try withCoordinatedURL(source) { coordinated in
            let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw importError("音频文件为空或不可读取") }
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard available > Int64(values.fileSize ?? 0) + 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
            try manager.copyItem(at: coordinated, to: staging)
        }
        let probe = try AVAudioPlayer(contentsOf: staging)
        guard probe.duration.isFinite, probe.duration > 0 else { throw importError("音频无法解码") }
        var stem = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasPrefix(".") { stem.removeFirst() }
        if stem.isEmpty { stem = "未命名歌曲" }
        while stem.utf8.count > 170 { stem.removeLast() }
        var destination = directory.appendingPathComponent(AudioFileFormat.fileName(stem: stem, format: format))
        var suffix = 2
        while manager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(AudioFileFormat.fileName(stem: stem, format: format, duplicateIndex: suffix))
            suffix += 1
        }
        try manager.moveItem(at: staging, to: destination)
        return destination
    }

    private static func withCoordinatedURL<T>(_ source: URL, perform: (URL) throws -> T) throws -> T {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result { try perform(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw importError("无法协调读取所选文件") }
        return try result.get()
    }

    static func importError(_ message: String) -> NSError {
        NSError(domain: "PhoneResourceImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
