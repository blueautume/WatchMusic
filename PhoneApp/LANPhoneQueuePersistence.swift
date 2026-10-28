import Foundation

struct LANQueuedTrackLocation: Codable, Hashable {
    let folder: String
    let fileName: String

    var isValid: Bool {
        LANTransferValidation.isSafeComponent(folder) && LANTransferValidation.isSafeComponent(fileName) &&
            AudioFileFormat.supports(URL(fileURLWithPath: fileName))
    }
}

/// Credentials are intentionally excluded. Restoring the queue creates a fresh
/// HTTP session, verifies sources, and checks Watch inventory before sending.
struct LANPhoneQueueSnapshot: Codable {
    var orderedRecordIDs: [String]
    var submissions: [[LANQueuedTrackLocation]]
    var globallyPaused: Bool
}
