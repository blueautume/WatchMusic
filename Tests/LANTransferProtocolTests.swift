import Foundation

@main
struct LANTransferProtocolTests {
    static var assertions = 0
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let sessionID = UUID().uuidString
    static let fileID = UUID().uuidString
    static let hash = String(repeating: "a", count: 64)
    static let token = String(repeating: "b", count: 64)

    static func file(id: String = fileID, folder: String = "音乐", name: String = "测试.flac", bytes: Int64 = 100, digest: String = hash) -> LANTransferFile {
        LANTransferFile(id: id, folder: folder, fileName: name, byteCount: bytes, sha256: digest)
    }

    static func offer(version: Int = 1, session: String = sessionID, secret: String = token,
                      urls: [URL] = [URL(string: "http://192.168.5.99:49152")!],
                      expiry: Date = now.addingTimeInterval(900), files: [LANTransferFile] = [file()]) -> LANTransferOffer {
        LANTransferOffer(protocolVersion: version, sessionID: session, token: secret, baseURLs: urls, expiresAt: expiry, files: files)
    }

    static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        assertions += 1
        guard try value() else { throw NSError(domain: "LANTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }

    static func rejected(_ offer: LANTransferOffer) -> Bool {
        do { try LANTransferValidation.validate(offer, now: now); return false } catch { return true }
    }

    static func main() throws {
        try LANTransferValidation.validate(offer(), now: now)
        for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.0.1", "169.254.10.20"] {
            try expect(LANTransferValidation.isPrivateIPv4(ip), "private address accepted: \(ip)")
        }
        for ip in ["8.8.8.8", "127.0.0.1", "172.15.0.1", "172.32.0.1", "192.169.1.1", "10.0.0.256", "10.0.1", "10.0.0.1.evil.test", "010.0.0.1", "0x0a.0.0.1", "10.0.0.-1", "10.0.0.1 ", "::1"] {
            try expect(!LANTransferValidation.isPrivateIPv4(ip), "non-local or ambiguous address rejected: \(ip)")
        }
        try expect(LANTransferValidation.isPrivateIPv4("127.0.0.1", allowLoopback: true), "explicit test-only loopback")
        for address in ["http://8.8.8.8:80", "https://192.168.1.2:80", "http://user:pass@192.168.1.2:80", "http://192.168.1.2:80/other", "http://192.168.1.2:80?token=secret", "http://192.168.1.2:80#fragment", "http://example.com:80", "http://192.168.1.2:0"] {
            try expect(rejected(offer(urls: [URL(string: address)!])), "endpoint rejected: \(address)")
        }
        try expect(rejected(offer(version: 2)), "unsupported protocol rejected")
        try expect(rejected(offer(session: "not-a-uuid")), "invalid session rejected")
        try expect(rejected(offer(secret: "short")), "weak/malformed token rejected")
        try expect(rejected(offer(expiry: now)), "expired offer rejected")
        try expect(rejected(offer(expiry: now.addingTimeInterval(3_601))), "unbounded offer lifetime rejected")
        try expect(rejected(offer(urls: [])), "missing endpoint rejected")
        try expect(rejected(offer(files: [])), "empty manifest rejected")
        try expect(rejected(offer(files: [file(), file()])), "duplicate IDs rejected")
        try expect(rejected(offer(files: [file(), file(id: UUID().uuidString)])), "duplicate destination rejected")
        try expect(rejected(offer(files: [file(name: "song.mp3"), file(id: UUID().uuidString, name: "SONG.MP3")])), "case-folded destination collision rejected")
        for name in ["../escape", ".hidden", "a/b", "a\\b", "a:b", "bad\nname", "bad\0name", " ", "file "] {
            try expect(rejected(offer(files: [file(folder: name)])), "unsafe directory rejected")
        }
        try expect(rejected(offer(files: [file(name: "payload.exe")])), "unsupported audio rejected")
        try expect(rejected(offer(files: [file(bytes: 0)])), "empty file rejected")
        try expect(rejected(offer(files: [file(bytes: Int64.max)])), "oversized file rejected")
        try expect(rejected(offer(files: [file(digest: "invalid")])), "malformed hash rejected")
        let message = try LANTransferWire.message(offer(), type: LANTransferWire.offerType)
        let decoded = LANTransferWire.decode(LANTransferOffer.self, from: message, type: LANTransferWire.offerType)
        try expect(decoded?.files == offer().files && decoded?.token == token, "manifest wire round trip")
        try expect(LANTransferWire.decode(LANTransferOffer.self, from: message, type: LANTransferWire.eventType) == nil, "message type cannot be confused")
        try expect(LANTransferWire.decode(LANTransferOffer.self, from: ["type": LANTransferWire.offerType, "payload": Data(repeating: 0, count: 1_048_577)], type: LANTransferWire.offerType) == nil, "wire payload bounded")
        var pausedOffer = offer()
        pausedOffer.pausedFileIDs = [fileID]
        try expect(!rejected(pausedOffer), "preparation pause may reference an offered file")
        pausedOffer.pausedFileIDs = [UUID().uuidString]
        try expect(rejected(pausedOffer), "preparation pause cannot reference another file")
        pausedOffer.pausedFileIDs = [fileID, fileID]
        try expect(rejected(pausedOffer), "duplicate paused intents rejected")
        try expect(decoded?.pausedFileIDs == nil, "legacy manifests decode without pause metadata")
        let command = LANTransferCommand(sessionID: sessionID, kind: .pause, fileID: nil,
                                          fileIDs: [fileID], controlRevision: 42)
        let controlMessage = try LANTransferWire.message(command, type: LANTransferWire.commandType)
        let decodedCommand = LANTransferWire.decode(LANTransferCommand.self, from: controlMessage, type: LANTransferWire.commandType)
        try expect(decodedCommand?.kind == .pause && decodedCommand?.fileIDs == [fileID] && decodedCommand?.controlRevision == 42,
                   "batch pause preserves identities and monotonic revision on the wire")
        let legacyCancel = try JSONDecoder().decode(LANTransferCommand.self, from: Data("{\"sessionID\":\"\(sessionID)\",\"kind\":\"cancel\",\"fileID\":\"\(fileID)\"}".utf8))
        try expect(legacyCancel.kind == .cancel && legacyCancel.fileIDs == nil, "legacy cancellation remains wire compatible")
        let pausedEvent = LANTransferEvent(sessionID: sessionID, fileID: fileID, kind: .paused,
                                            completedBytes: 35, totalBytes: 100, message: nil, controlRevision: 42)
        let reply = try LANTransferWire.message(LANTransferControlReply(events: [pausedEvent]), type: LANTransferWire.controlReplyType)
        let decodedReply = LANTransferWire.decode(LANTransferControlReply.self, from: reply, type: LANTransferWire.controlReplyType)
        try expect(decodedReply?.events.first?.controlRevision == 42 && decodedReply?.events.first?.kind == .paused,
                   "control acknowledgement is separate from terminal receipts")
        try expect(!LANTransferEvent.Kind.paused.isTerminal && !LANTransferEvent.Kind.resumed.isTerminal,
                   "pause and start are not terminal states")
        try expect(LANTransferValidation.isValidDownloadResponse(statusCode: 200, contentRange: nil, expectedByteCount: 100),
                   "ordinary whole-file response accepted")
        for header in ["bytes 0-99/100", "bytes 35-99/100", "bytes 99-99/100", "BYTES 0-99/100"] {
            try expect(LANTransferValidation.isValidDownloadResponse(statusCode: 206, contentRange: header, expectedByteCount: 100),
                       "resume response may end the complete offered resource: \(header)")
        }
        for header in ["", "bytes */100", "bytes 0-99/*", "bytes 0-99/101", "bytes 0-98/100", "bytes 100-99/100",
                       "bytes -1-99/100", "bytes +0-99/100", "bytes ０-99/100", "bytes 0-99/100, bytes 0-99/100",
                       "bytes 0-99/100/100", "bytes  0-99/100", "bytes\t0-99/100", "items 0-99/100",
                       "bytes 0-9223372036854775808/100"] {
            try expect(!LANTransferValidation.isValidDownloadResponse(statusCode: 206, contentRange: header, expectedByteCount: 100),
                       "malformed or mismatched resume response rejected: \(header)")
        }
        try expect(!LANTransferValidation.isValidDownloadResponse(statusCode: 206, contentRange: nil, expectedByteCount: 100),
                   "partial response must identify a range")
        try expect(!LANTransferValidation.isValidDownloadResponse(statusCode: 416, contentRange: "bytes 0-99/100", expectedByteCount: 100),
                   "range failure cannot be treated as a successful response")
        try expect(!LANTransferValidation.isValidDownloadResponse(statusCode: 200, contentRange: nil, expectedByteCount: 0),
                   "zero-sized offered resource cannot be accepted")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data("abc".utf8).write(to: temp)
        try expect(LANFileDigest.sha256(of: temp) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "known SHA-256 vector")
        let chunkedVector = Data((0..<131_073).map { UInt8($0 % 251) })
        try chunkedVector.write(to: temp)
        try expect(LANFileDigest.sha256(of: temp) == "dd84db969f4ff2abb79c8c2fbc06e8d8e02c46d6481c958e057f7ad7a24c58a7",
                   "SHA-256 remains correct across two complete chunks and a final byte")
        var cancelledBeforeRead = false
        do { _ = try LANFileDigest.sha256(of: temp) { throw CancellationError() } }
        catch is CancellationError { cancelledBeforeRead = true }
        try expect(cancelledBeforeRead, "cancellation before reading never returns a digest")
        var checks = 0
        var cancelledBetweenChunks = false
        do {
            _ = try LANFileDigest.sha256(of: temp) {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }
        } catch is CancellationError { cancelledBetweenChunks = true }
        try expect(cancelledBetweenChunks && checks == 2, "in-progress hashing stops at the next bounded-read cancellation check")
        try Data().write(to: temp)
        try expect(LANFileDigest.sha256(of: temp) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                   "empty input has the standard SHA-256 digest")
        print("PASS: \(assertions) LAN protocol assertions")
    }
}
