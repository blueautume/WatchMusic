import Foundation
import Darwin

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
        var sourceProgress: [LANSourceProgress] = []
        server.onStopped = { stoppedReasons.append($0) }
        server.onProgress = { sourceProgress.append($0) }
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
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(sourceProgress.contains { $0.fileID == firstID && $0.sentBytes == Int64(expectedData.count) && $0.totalBytes == Int64(expectedData.count) },
                   "Successful source writes publish a complete logical file position")
        let rangeProgressStart = sourceProgress.count
        let partial = try await request(range: "bytes=10-99")
        try expect(partial.1.statusCode == 206 && partial.0 == expectedData.subdata(in: 10..<100), "Single byte range is streamed exactly")
        try expect(partial.1.value(forHTTPHeaderField: "Content-Range") == "bytes 10-99/\(expectedData.count)", "Partial response identifies its byte interval")
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(sourceProgress.dropFirst(rangeProgressStart).contains {
            $0.fileID == firstID && $0.sentBytes == 100 && $0.totalBytes == Int64(expectedData.count)
        }, "Range progress includes the requested offset and only successfully sent body bytes")
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

        // Reusing an in-memory digest still binds it to the complete file
        // identity. Preserving size and mtime cannot hide a source mutation.
        let verifiedCopy = directory.appendingPathComponent("verified.flac")
        try manager.copyItem(at: fixture, to: verifiedCopy)
        let verifiedID = UUID().uuidString
        let verifiedFile = LANTransferFile(id: verifiedID, folder: "Verified", fileName: "verified.flac",
            byteCount: Int64(expectedData.count), sha256: try LANFileDigest.sha256(of: verifiedCopy))
        let fingerprint = LANHTTPVerifiedSource(url: verifiedCopy, file: verifiedFile,
                                                version: try TransferSourceVersion.read(verifiedCopy))
        let verifiedSources = [LANTransferSource(id: verifiedID, folder: "Verified", fileName: "verified.flac", url: verifiedCopy)]
        let verifiedServer = LANHTTPServer(allowLoopbackForTesting: true)
        defer { verifiedServer.stop() }
        let verifiedOffer = try await verifiedServer.start(sources: verifiedSources, verifiedSources: [verifiedID: fingerprint])
        try expect(verifiedOffer.files == [verifiedFile], "Verified metadata preserves the inspected file identity and digest")
        var verifiedRequest = URLRequest(url: verifiedOffer.baseURLs[0].appendingPathComponent("v1/files").appendingPathComponent(verifiedID))
        verifiedRequest.setValue("Bearer " + verifiedOffer.token, forHTTPHeaderField: "Authorization")
        let (verifiedBody, verifiedResponse) = try await session.data(for: verifiedRequest)
        try expect((verifiedResponse as? HTTPURLResponse)?.statusCode == 200 && verifiedBody == expectedData,
                   "A source prepared from an in-memory fingerprint streams the original audio")
        let priorAttributes = try manager.attributesOfItem(atPath: verifiedCopy.path)
        var altered = expectedData
        altered[altered.startIndex] ^= 1
        try altered.write(to: verifiedCopy)
        if let priorDate = priorAttributes[.modificationDate] {
            try manager.setAttributes([.modificationDate: priorDate], ofItemAtPath: verifiedCopy.path)
        }
        let changedVersion = try TransferSourceVersion.read(verifiedCopy)
        try expect(changedVersion != fingerprint.version,
                   "The source version detects an in-place rewrite with restored size and mtime")
        let (changedBody, changedResponse) = try await session.data(for: verifiedRequest)
        try expect((changedResponse as? HTTPURLResponse)?.statusCode == 409 && changedBody.isEmpty,
                   "An old verified source rejects changed content before returning bytes")
        verifiedServer.stop()
        let rehashed = try await verifiedServer.start(sources: verifiedSources, verifiedSources: [verifiedID: fingerprint])
        let alteredHash = try LANFileDigest.sha256(of: verifiedCopy)
        try expect(rehashed.files[0].sha256 == alteredHash && alteredHash != verifiedFile.sha256,
                   "A stale fingerprint is rehashed rather than trusted when opening a new source")

        let linkedCopy = directory.appendingPathComponent("linked.flac")
        try manager.createSymbolicLink(at: linkedCopy, withDestinationURL: verifiedCopy)
        let linkedServer = LANHTTPServer(allowLoopbackForTesting: true)
        defer { linkedServer.stop() }
        do {
            _ = try await linkedServer.start(sources: [LANTransferSource(id: UUID().uuidString,
                folder: "Linked", fileName: "linked.flac", url: linkedCopy)])
            throw ProbeError.failed("A symlink must not pass source version validation")
        } catch let error as ProbeError { throw error }
        catch { assertions += 1 }
        try await slowReaderChecks(in: directory)
    }

    @MainActor private static func slowReaderChecks(in directory: URL) async throws {
        let large = directory.appendingPathComponent("slow.flac")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let output = try FileHandle(forWritingTo: large)
        let block = Data(repeating: 0x51, count: 1_024 * 1_024)
        for _ in 0..<16 { try output.write(contentsOf: block) }
        try output.close()
        let fileID = UUID().uuidString
        let sources = [LANTransferSource(id: fileID, folder: "Slow", fileName: "slow.flac", url: large)]
        let server = LANHTTPServer(allowLoopbackForTesting: true, headerTimeout: 0.2, transferIdleTimeout: 1.2)
        defer { server.stop() }
        var events: [LANSourceProgress] = []
        server.onProgress = { events.append($0) }
        let offer = try await server.start(sources: sources)
        let url = offer.baseURLs[0].appendingPathComponent("v1/files").appendingPathComponent(fileID)
        let token = offer.token
        let total = 16 * 1_024 * 1_024

        let slow = try await Task.detached {
            try socketRequest(url: url, token: token, pauseAfterHeader: 0.6)
        }.value
        try expect(slow.status == 200 && slow.bodyBytes == total && slow.matchesPayload,
                   "A real slow reader survives backpressure longer than the separate header timeout")
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(events.last?.sentBytes == Int64(total) && events.last?.totalBytes == Int64(total),
                   "The slow-reader source reaches completion after reading resumes")
        try expect(events.count <= Int(ceil(slow.elapsed)) + 2,
                   "Source progress is throttled to one update per second plus completion")

        let idleProgressStart = events.count
        let idle = try await Task.detached {
            try socketRequest(url: url, token: token, pauseAfterHeader: 1.8)
        }.value
        try expect(idle.status == 200 && idle.bodyBytes > 0 && idle.bodyBytes < total,
                   "A reader stalled beyond the injected transfer timeout is disconnected before a complete body")
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(!events.dropFirst(idleProgressStart).contains { $0.sentBytes == Int64(total) },
                   "A disconnected stream never publishes false source completion")
        try expect(server.activeSessionID == offer.sessionID, "A stalled client does not close the shared source listener")

        let cut = try await Task.detached {
            try socketRequest(url: url, token: token, abortAfterBytes: 131_072)
        }.value
        try expect(cut.status == 200 && cut.bodyBytes >= 131_072 && cut.bodyBytes < total,
                   "A real reader can disconnect mid-stream without receiving the entire file")

        let cancellation = Task.detached {
            try socketRequest(url: url, token: token, pauseAfterHeader: 0.6)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        server.cancel(fileID: fileID)
        let progressAtCancel = events.count
        let cancelled = try await cancellation.value
        try expect(cancelled.status == 200 && cancelled.bodyBytes < total,
                   "File cancellation closes an in-flight slow reader")
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(events.count == progressAtCancel, "Cancelled files cannot publish queued or late source progress")

        let header = try await Task.detached {
            try socketRequest(url: url, token: token, delayHeader: 0.5)
        }.value
        try expect(header.status == nil && header.bodyBytes == 0,
                   "The short header timeout still closes a client that never sends its request promptly")

        // Hold the main actor until real body bytes have reached a reader, then
        // retire the source before its queued progress jobs can be delivered.
        server.stop()
        events.removeAll()
        let retiringOffer = try await server.start(sources: sources)
        let retiringURL = retiringOffer.baseURLs[0].appendingPathComponent("v1/files").appendingPathComponent(fileID)
        let bodyStarted = DispatchSemaphore(value: 0)
        let retiringRead = Task.detached {
            try socketRequest(url: retiringURL, token: retiringOffer.token, pauseAfterHeader: 0.6,
                              firstBodySignal: bodyStarted)
        }
        let began = holdProgressDelivery(until: bodyStarted)
        server.stop()
        let retired = try await retiringRead.value
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(began && retired.bodyBytes > 0 && retired.bodyBytes < total,
                   "A source can be retired after sending real bytes while main-actor progress delivery is queued")
        try expect(events.isEmpty, "A retired source generation cannot deliver queued progress callbacks")
    }

    /// Deliberately keep this synchronous: this test needs queued main-actor
    /// callbacks to remain undelivered until the source generation is retired.
    @MainActor private static func holdProgressDelivery(until bodyStarted: DispatchSemaphore) -> Bool {
        let began = bodyStarted.wait(timeout: .now() + 2) == .success
        Thread.sleep(forTimeInterval: 0.05)
        return began
    }

    private struct SocketResult: Sendable {
        let status: Int?
        let bodyBytes: Int
        let matchesPayload: Bool
        let elapsed: TimeInterval
    }

    /// A bounded-buffer BSD reader makes TCP backpressure real. It runs off the
    /// main actor, so the production NWListener and progress callbacks can run.
    nonisolated private static func socketRequest(url: URL, token: String, pauseAfterHeader: TimeInterval = 0,
                                                   delayHeader: TimeInterval = 0, abortAfterBytes: Int? = nil,
                                                   firstBodySignal: DispatchSemaphore? = nil) throws -> SocketResult {
        let started = ProcessInfo.processInfo.systemUptime
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError() }
        defer { Darwin.close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var receiveBuffer: Int32 = 16_384
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer)))
        var readTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout.size(ofValue: readTimeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(url.port!).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw socketError() }
        if delayHeader > 0 { Thread.sleep(forTimeInterval: delayHeader) }
        let request = Data("GET \(url.path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            let count = request.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: sent), request.count - sent, 0) }
            if count <= 0 { return SocketResult(status: nil, bodyBytes: 0, matchesPayload: true, elapsed: ProcessInfo.processInfo.systemUptime - started) }
            sent += count
        }
        var header = Data(), status: Int?, bodyBytes = 0, matches = true, didSignalBody = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { break }
            var body = Data(buffer.prefix(count))
            if status == nil {
                header.append(body)
                guard let end = header.range(of: Data("\r\n\r\n".utf8)) else { continue }
                status = String(decoding: header[..<end.lowerBound], as: UTF8.self).split(separator: " ").dropFirst().first.flatMap { Int($0) }
                body = Data(header[end.upperBound...])
                header.removeAll()
                if pauseAfterHeader > 0 { Thread.sleep(forTimeInterval: pauseAfterHeader) }
                receiveBuffer = 1_048_576
                setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer)))
            }
            bodyBytes += body.count
            if !didSignalBody, bodyBytes > 0 { didSignalBody = true; firstBodySignal?.signal() }
            matches = matches && body.allSatisfy { $0 == 0x51 }
            if let abortAfterBytes, bodyBytes >= abortAfterBytes { break }
        }
        return SocketResult(status: status, bodyBytes: bodyBytes, matchesPayload: matches,
                            elapsed: ProcessInfo.processInfo.systemUptime - started)
    }

    nonisolated private static func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

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
