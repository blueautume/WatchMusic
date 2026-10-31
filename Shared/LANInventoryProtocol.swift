import Foundation

/// Candidates are local content fingerprints, not playback metadata. Replies
/// contain only the IDs whose exact destination already has the same content.
struct LANInventoryRequest: Codable, Sendable {
    let requestID: String
    let files: [LANTransferFile]
}

struct LANInventoryReply: Codable, Sendable {
    let requestID: String
    let matchedFileIDs: [String]
}

enum LANInventoryWire {
    static let requestType = "lan.inventory.v1"
    static let replyType = "lan.inventory-reply.v1"
    static let maximumFiles = 10

    static func validate(_ request: LANInventoryRequest) throws {
        guard UUID(uuidString: request.requestID) != nil,
              !request.files.isEmpty, request.files.count <= maximumFiles,
              Set(request.files.map(\.id)).count == request.files.count else { throw invalidRequest() }
        var paths = Set<String>()
        for file in request.files {
            guard UUID(uuidString: file.id) != nil,
                  LANTransferValidation.isSafeComponent(file.folder),
                  LANTransferValidation.isSafeComponent(file.fileName),
                  AudioFileFormat.supports(URL(fileURLWithPath: file.fileName)),
                  file.byteCount > 0, file.byteCount <= 8 * 1_024 * 1_024 * 1_024,
                  validDigest(file.sha256),
                  paths.insert(pathKey(folder: file.folder, fileName: file.fileName)).inserted else { throw invalidRequest() }
        }
    }

    static func validate(_ reply: LANInventoryReply, for request: LANInventoryRequest) throws {
        try validate(request)
        guard reply.requestID == request.requestID,
              Set(reply.matchedFileIDs).count == reply.matchedFileIDs.count,
              Set(reply.matchedFileIDs).isSubset(of: Set(request.files.map(\.id))) else { throw invalidRequest() }
    }

    static func pathKey(folder: String, fileName: String) -> String {
        (folder + "/" + fileName).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    private static func invalidRequest() -> NSError {
        NSError(domain: "LANInventory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.text("歌曲检查信息无效，请重新选择。")])
    }
}
