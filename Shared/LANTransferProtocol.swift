import CryptoKit
import Foundation

struct LANTransferSource {
    let id: String
    let folder: String
    let fileName: String
    let url: URL
}

struct LANTransferFile: Codable, Equatable {
    let id: String
    let folder: String
    let fileName: String
    let byteCount: Int64
    let sha256: String
}

struct LANTransferOffer: Codable {
    var protocolVersion = 1
    let sessionID: String
    let token: String
    let baseURLs: [URL]
    let expiresAt: Date
    let files: [LANTransferFile]
}

struct LANTransferEvent: Codable {
    enum Kind: String, Codable { case progress, stored, failed, cancelled }
    let sessionID: String
    let fileID: String
    let kind: Kind
    let completedBytes: Int64
    let totalBytes: Int64
    let message: String?
}

struct LANTransferCommand: Codable {
    enum Kind: String, Codable { case cancel, stop }
    let sessionID: String
    let kind: Kind
    let fileID: String?
}

enum LANTransferWire {
    static let offerType = "lan.offer.v1"
    static let eventType = "lan.event.v1"
    static let commandType = "lan.command.v1"

    static func message<T: Encodable>(_ payload: T, type: String) throws -> [String: Any] {
        ["type": type, "payload": try JSONEncoder().encode(payload)]
    }

    static func decode<T: Decodable>(_ model: T.Type, from message: [String: Any], type: String) -> T? {
        guard message["type"] as? String == type, let data = message["payload"] as? Data,
              data.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(model, from: data)
    }
}

enum LANTransferValidation {
    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !value.hasPrefix(".") && value.utf8.count <= 240 &&
        !value.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" }) &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func isPrivateIPv4(_ host: String, allowLoopback: Bool = false) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || !$0.hasPrefix("0")) && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1]),
              UInt8(parts[2]) != nil, UInt8(parts[3]) != nil else { return false }
        return a == 10 || (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) || (a == 169 && b == 254) || (allowLoopback && a == 127)
    }

    static func isLocalBaseURL(_ url: URL, allowLoopback: Bool = false) -> Bool {
        guard url.scheme == "http", let host = url.host,
              isPrivateIPv4(host, allowLoopback: allowLoopback),
              let port = url.port, (1...65_535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        return true
    }

    static func validate(_ offer: LANTransferOffer, now: Date = Date(), allowLoopback: Bool = false) throws {
        guard offer.protocolVersion == 1, UUID(uuidString: offer.sessionID) != nil,
              offer.token.count == 64, offer.token.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              offer.expiresAt > now, offer.expiresAt.timeIntervalSince(now) <= 3_600,
              !offer.baseURLs.isEmpty, offer.baseURLs.count <= 8,
              offer.baseURLs.allSatisfy({ isLocalBaseURL($0, allowLoopback: allowLoopback) }),
              !offer.files.isEmpty, offer.files.count <= 1_000,
              Set(offer.files.map(\.id)).count == offer.files.count else { throw invalidOffer() }
        var paths = Set<String>()
        for file in offer.files {
            guard UUID(uuidString: file.id) != nil, isSafeComponent(file.folder), isSafeComponent(file.fileName),
                  AudioFileFormat.supports(URL(fileURLWithPath: file.fileName)),
                  file.byteCount > 0, file.byteCount <= 8 * 1_024 * 1_024 * 1_024,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
                  paths.insert((file.folder + "/" + file.fileName).precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalidOffer() }
        }
    }

    private static func invalidOffer() -> NSError {
        NSError(domain: "LANTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "局域网传输信息无效或已过期。"])
    }
}

enum LANFileDigest {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
