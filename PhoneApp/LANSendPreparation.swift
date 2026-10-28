import Foundation

struct LANSendCandidate: Sendable {
    let track: PhoneTrack
    let file: LANTransferFile
    let version: TransferSourceVersion
}

enum LANSendPreparation {
    static func prepare(_ tracks: [PhoneTrack]) async throws -> [LANSendCandidate] {
        let task = Task.detached(priority: .utility) {
            try tracks.map { track in
                try Task.checkCancellation()
                let before = try TransferSourceVersion.read(track.url)
                guard before.byteCount > 0, before.byteCount <= 8 * 1_024 * 1_024 * 1_024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let hash = try LANFileDigest.sha256(of: track.url) { try Task.checkCancellation() }
                guard before == (try TransferSourceVersion.read(track.url)) else {
                    throw NSError(domain: "LANSendPreparation", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "歌曲文件已变化，请重新发送。"])
                }
                let file = LANTransferFile(id: UUID().uuidString, folder: track.folder, fileName: track.fileName,
                                           byteCount: before.byteCount, sha256: hash)
                return LANSendCandidate(track: track, file: file, version: before)
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
