import Foundation
#if os(iOS)
import UniformTypeIdentifiers
#endif

/// The same allow-list is used for import, library scans and WatchConnectivity.
/// Keep the source extension when copying or renaming; files are never transcoded.
enum AudioFileFormat: String, CaseIterable {
    case mp3, flac

    var displayName: String { rawValue.uppercased() }

    static func format(for url: URL) -> AudioFileFormat? {
        AudioFileFormat(rawValue: url.pathExtension.lowercased())
    }

    static func supports(_ url: URL) -> Bool { format(for: url) != nil }

    static func fileName(stem: String, format: AudioFileFormat, duplicateIndex: Int = 1) -> String {
        duplicateIndex > 1 ? "\(stem) (\(duplicateIndex)).\(format.rawValue)" : "\(stem).\(format.rawValue)"
    }

    #if os(iOS)
    static var importContentTypes: [UTType] {
        [.mp3, UTType(filenameExtension: "flac", conformingTo: .audio)
            ?? UTType(importedAs: "org.xiph.flac", conformingTo: .audio)]
    }
    #endif
}
