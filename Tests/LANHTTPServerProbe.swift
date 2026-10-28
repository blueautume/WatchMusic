import Foundation

@main
struct LANHTTPServerProbe {
    @MainActor static var assertions = 0

    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw ProbeError.failed(message) }
        assertions += 1
    }

    @MainActor static func main() async {
        do {
            try await run()
            print("PASS: \(assertions) real LAN HTTP server assertions")
        } catch {
            FileHandle.standardError.write(Data("LAN_HTTP_PROBE_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        try parserChecks()
        guard CommandLine.arguments.count == 2 else { throw ProbeError.failed("Usage: LANHTTPServerProbe AUDIO_FIXTURE") }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("LANHTTPServerProbe-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let copy = directory.appendingPathComponent("测试旋律.flac")
        try manager.copyItem(at: fixture, to: copy)
        let expectedData = try Data(contentsOf: copy)
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let sources = [LANTransferSource(id: firstID, folder: "测试目录", fileName: "测试旋律.flac", url: copy),
                       LANTransferSource(id: secondID, folder: "其他目录", fileName: "测试旋律.flac", url: copy)]
        let server = LANHTTPServer(allowLoopbackForTesting: true)
        defer { server.stop() }
        var stoppedReasons: [String] = []
        server.onStopped = { stoppedReasons.append($0) }
        let offer = try await server.start(sources: sources)
        try LANTransferValidation.validate(offer, allowLoopback: true)
        try expect(server.activeSessionID == offer.sessionID, "A ready offer identifies the active session")
        try expect(offer.baseURLs.count == 1 && offer.baseURLs[0].host == "127.0.0.1", "Test listener binds only loopback")
        try expect(offer.files.count == 2 && offer.files[0].byteCount == Int64(expectedData.count), "Offer records actual file sizes")
        let expectedDigest = try LANFileDigest.sha256(of: copy)
        try expect(offer.files[0].sha256 == expectedDigest, "Offer digest matches the actual streamed file")
        var secondStartRejected = false
        do { _ = try await server.start(sources: sources) }
        catch { secondStartRejected = true }
        try expect(secondStartRejected, "A second start must not replace a live session")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func request(_ fileID: String = firstID, token: String? = offer.token,
                     method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            let url = offer.baseURLs[0].appendingPathComponent("v1/files").appendingPathComponent(fileID)
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProbeError.failed("Non-HTTP response") }
            return (data, http)
        }
        let missing = try await request(token: nil)
        try expect(missing.1.statusCode == 401 && missing.0.isEmpty, "Missing bearer never exposes bytes")
        let incorrect = try await request(token: String(repeating: "0", count: 64))
        try expect(incorrect.1.statusCode == 401 && incorrect.0.isEmpty, "Wrong bearer never exposes bytes")
        let unknown = try await request(UUID().uuidString)
        try expect(unknown.1.statusCode == 404, "Only explicitly offered file UUIDs are reachable")
        let traversal = try await request("%2e%2e%2fConfig%2fPhoneInfo.plist")
        try expect(traversal.1.statusCode == 404, "Traversal cannot select a filesystem path")
        let post = try await request(method: "POST")
        try expect(post.1.statusCode == 405 && post.1.value(forHTTPHeaderField: "Allow") == "GET", "Unsupported methods are rejected")
        let full = try await request()
        try expect(full.1.statusCode == 200 && full.0 == expectedData, "URLSession receives the full file over a real TCP connection")
        try expect(full.1.expectedContentLength == Int64(expectedData.count), "Response exposes an exact content length")
        try expect(full.1.value(forHTTPHeaderField: "Cache-Control") == "no-store", "Token-protected audio is not cached")
        let partial = try await request(range: "bytes=10-99")
        try expect(partial.1.statusCode == 206 && partial.0 == expectedData.subdata(in: 10..<100), "Single byte range is streamed exactly")
        try expect(partial.1.value(forHTTPHeaderField: "Content-Range") == "bytes 10-99/\(expectedData.count)", "Partial response identifies its byte interval")
        let suffix = try await request(range: "bytes=-64")
        try expect(suffix.1.statusCode == 206 && suffix.0 == expectedData.suffix(64), "Suffix ranges preserve final bytes")
        let open = try await request(range: "bytes=1000-")
        try expect(open.1.statusCode == 206 && open.0 == expectedData.dropFirst(1000), "Open-ended range reaches EOF")
        let invalid = try await request(range: "bytes=\(expectedData.count)-")
        try expect(invalid.1.statusCode == 416 && invalid.0.isEmpty, "Out-of-bounds range has no audio payload")
        try expect(invalid.1.value(forHTTPHeaderField: "Content-Range") == "bytes */\(expectedData.count)", "Unsatisfied range reports current total")
        let multi = try await request(range: "bytes=0-1,3-4")
        try expect(multi.1.statusCode == 416, "Unsupported multipart ranges fail explicitly")
        server.cancel(fileID: firstID)
        let cancelled = try await request()
        try expect(cancelled.1.statusCode == 404, "Cancellation immediately revokes file access")
        let sibling = try await request(secondID)
        try expect(sibling.1.statusCode == 200 && sibling.0 == expectedData, "Cancelling one file preserves another offered file")
        let mutation = try FileHandle(forWritingTo: copy)
        try mutation.seekToEnd()
        try mutation.write(contentsOf: Data([1]))
        try mutation.close()
        let changed = try await request(secondID)
        try expect(changed.1.statusCode == 409 && changed.0.isEmpty, "Changed source is rejected before stale metadata can be served")
        server.stop()
        try expect(server.activeSessionID == nil && stoppedReasons.isEmpty, "Intentional stop is silent and clears active state")
        do {
            _ = try await request(secondID)
            throw ProbeError.failed("Stopped listener must no longer serve audio")
        } catch let error as ProbeError { throw error }
        catch { assertions += 1 }

        let cancelledServer = LANHTTPServer(allowLoopbackForTesting: true)
        let preparation = Task { try await cancelledServer.start(sources: sources) }
        preparation.cancel()
        do {
            _ = try await preparation.value
            throw ProbeError.failed("Cancelled preparation must not expose a listener")
        } catch is CancellationError { assertions += 1 }
        try expect(cancelledServer.activeSessionID == nil, "Cancelled preparation leaves no active server")

        let expiringServer = LANHTTPServer(allowLoopbackForTesting: true, sessionLifetime: 1)
        defer { expiringServer.stop() }
        var expired = false
        expiringServer.onStopped = { _ in expired = true }
        _ = try await expiringServer.start(sources: sources)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try expect(expired && expiringServer.activeSessionID == nil, "Expiration closes the listener and notifies its owner")
    }

    @MainActor private static func parserChecks() throws {
        func rejected(_ request: String, status: Int = 400) throws {
            do { _ = try LANHTTPRequest(header: Data(request.utf8)) }
            catch let failure as LANHTTPFailure {
                try expect(failure.status == status, "Malformed HTTP request receives its bounded error")
                return
            }
            throw ProbeError.failed("Malformed HTTP request was accepted")
        }
        let id = UUID().uuidString
        let target = "/v1/files/" + id
        let valid = try LANHTTPRequest(header: Data("GET \(target) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer token\r\n\r\n".utf8))
        try expect(valid.fileID == id && valid.headers["authorization"] == "Bearer token", "Valid requests preserve only the exact file UUID")
        try rejected("GET \(target) HTTP/1.1\r\n\r\n")
        try rejected("GET \(target) HTTP/2\r\nHost: localhost\r\n\r\n")
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\r\nAuthorization: first\r\nAuthorization: second\r\n\r\n")
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n")
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\n")
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\r\nBad Header: value\r\n\r\n")
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\r\nX-Test: \u{1}\r\n\r\n")
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\nAuthorization: token\r\n\r\n")
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\r\nX-Large: " + String(repeating: "x", count: 16_384) + "\r\n\r\n", status: 431)
        try rejected("GET \(target) HTTP/1.1\r\nHost: localhost\r\n" + (0..<101).map { "X-\($0): value\r\n" }.joined() + "\r\n")
        for header in ["bytes=-0", "bytes=9-8", "bytes=0--2", "bytes=9223372036854775808-", "items=0-5"] {
            do { _ = try LANHTTPByteRange.resolve(header, size: 100) }
            catch let failure as LANHTTPFailure {
                try expect(failure.status == 416, "Invalid or overflowing byte ranges are rejected")
                continue
            }
            throw ProbeError.failed("Invalid range was accepted")
        }
        let clamped = try LANHTTPByteRange.resolve("bytes=97-999", size: 100)
        try expect(clamped == LANHTTPByteRange(offset: 97, length: 3, isPartial: true), "Oversized end clamps without overflowing the file")
    }

    private enum ProbeError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let value) = self { return value }; return nil }
    }
}
