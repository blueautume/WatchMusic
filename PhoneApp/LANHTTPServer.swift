import CryptoKit
import Darwin
import Foundation
import Network

/// A short-lived, Wi-Fi-only file server. Only an explicitly offered file UUID
/// and its per-session bearer token can be used to request a file.
@MainActor
final class LANHTTPServer {
    var onStopped: ((String) -> Void)?
    private(set) var activeSessionID: String?
    private var core: LANHTTPServerCore?
    private var generation = UUID()
    private var preparation: LANPreparationCancellation?
    private let allowLoopbackForTesting: Bool
    private let lifetime: TimeInterval

    init(allowLoopbackForTesting: Bool = false, sessionLifetime: TimeInterval = 900) {
        self.allowLoopbackForTesting = allowLoopbackForTesting
        lifetime = min(900, max(1, sessionLifetime))
    }

    func start(sources: [LANTransferSource]) async throws -> LANTransferOffer {
        guard preparation == nil, core == nil else { throw lanServerError("已有局域网传输，请先完成或停止。") }
        let requestID = UUID()
        generation = requestID
        let cancellation = LANPreparationCancellation()
        preparation = cancellation
        let testing = allowLoopbackForTesting
        let lifetime = lifetime
        do {
            return try await withTaskCancellationHandler {
                let prepared = try await Task.detached(priority: .utility) {
                    try LANHTTPServerCore.prepare(sources, cancellation: cancellation)
                }.value
                try Task.checkCancellation()
                guard generation == requestID, !cancellation.isCancelled else { throw CancellationError() }
                let addresses = testing ? ["127.0.0.1"] : LANHTTPServerCore.wifiAddresses()
                guard !addresses.isEmpty else { throw lanServerError("请让 iPhone 连接 Wi-Fi 后再试。") }
                let sessionID = UUID().uuidString
                let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
                let expiration = Date().addingTimeInterval(lifetime)
                let newCore = try LANHTTPServerCore(files: prepared, token: token, expiration: expiration, testing: testing)
                core = newCore
                newCore.onStopped = { [weak self] reason in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == requestID else { return }
                        self.generation = UUID()
                        self.preparation?.cancel()
                        self.core = nil
                        self.preparation = nil
                        self.activeSessionID = nil
                        self.onStopped?(reason)
                    }
                }
                let port = try await newCore.start()
                try Task.checkCancellation()
                guard generation == requestID, !cancellation.isCancelled else {
                    newCore.stop()
                    throw CancellationError()
                }
                let offer = LANTransferOffer(sessionID: sessionID, token: token,
                                             baseURLs: addresses.compactMap { URL(string: "http://\($0):\(port)") },
                                             expiresAt: expiration, files: prepared.map(\.metadata))
                try LANTransferValidation.validate(offer, allowLoopback: testing)
                preparation = nil
                activeSessionID = sessionID
                return offer
            } onCancel: {
                cancellation.cancel()
                Task { @MainActor [weak self] in
                    guard let self, self.generation == requestID else { return }
                    self.stop()
                }
            }
        } catch {
            if generation == requestID { stop() }
            throw error
        }
    }

    func stop() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        activeSessionID = nil
        core?.stop()
        core = nil
    }

    func cancel(fileID: String) { core?.cancel(fileID: fileID) }
}

private func lanServerError(_ text: String) -> NSError {
    NSError(domain: "LANHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

private final class LANPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private struct LANFileAttributes {
    let isRegularFile: Bool
    let byteCount: Int64
    let modificationDate: Date?

    static func read(_ url: URL) throws -> LANFileAttributes {
        // URL resource values may be cached; file mutation checks must hit the filesystem.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return LANFileAttributes(isRegularFile: values[.type] as? FileAttributeType == .typeRegular,
                                 byteCount: (values[.size] as? NSNumber)?.int64Value ?? 0,
                                 modificationDate: values[.modificationDate] as? Date)
    }
}

private struct LANPreparedFile {
    let metadata: LANTransferFile
    let url: URL
    let modificationDate: Date?
}

private final class LANHTTPServerCore: @unchecked Sendable {
    var onStopped: ((String) -> Void)?
    private let queue = DispatchQueue(label: "WatchMusic.LANHTTPServer", qos: .utility)
    private let listener: NWListener
    private var files: [String: LANPreparedFile]
    private var token: String
    private let expiration: Date
    private var clients: [UUID: LANHTTPClient] = [:]
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var ready = false
    private var stopped = false
    private var startupTimeout: DispatchWorkItem?
    private var expirationTimer: DispatchWorkItem?

    init(files: [LANPreparedFile], token: String, expiration: Date, testing: Bool) throws {
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.metadata.id, $0) })
        self.token = token
        self.expiration = expiration
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        if testing {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        } else { parameters.requiredInterfaceType = .wifi }
        listener = try NWListener(using: parameters, on: .any)
    }

    static func prepare(_ sources: [LANTransferSource], cancellation: LANPreparationCancellation) throws -> [LANPreparedFile] {
        guard !sources.isEmpty, sources.count <= 1_000, Set(sources.map(\.id)).count == sources.count else {
            throw lanServerError("请选择需要发送的歌曲。")
        }
        var paths = Set<String>()
        return try sources.map { source in
            guard !cancellation.isCancelled else { throw CancellationError() }
            guard UUID(uuidString: source.id) != nil,
                  LANTransferValidation.isSafeComponent(source.folder), LANTransferValidation.isSafeComponent(source.fileName),
                  AudioFileFormat.supports(URL(fileURLWithPath: source.fileName)),
                  paths.insert(source.folder + "/" + source.fileName).inserted else { throw lanServerError("歌曲传输信息无效。") }
            let before = try LANFileAttributes.read(source.url)
            guard before.isRegularFile, before.byteCount > 0,
                  before.byteCount <= 8 * 1_024 * 1_024 * 1_024 else { throw lanServerError("歌曲文件为空或无法读取。") }
            let digest = try digest(source.url, cancellation: cancellation)
            let after = try LANFileAttributes.read(source.url)
            guard before.byteCount == after.byteCount, before.modificationDate == after.modificationDate else { throw lanServerError("歌曲文件已发生变化，请重新发送。") }
            return LANPreparedFile(metadata: LANTransferFile(id: source.id, folder: source.folder, fileName: source.fileName,
                                                            byteCount: before.byteCount, sha256: digest),
                                   url: source.url, modificationDate: after.modificationDate)
        }
    }

    private static func digest(_ url: URL, cancellation: LANPreparationCancellation) throws -> String {
        // Check cancellation between bounded reads, including large FLAC files.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            guard !cancellation.isCancelled else { throw CancellationError() }
            guard let data = try handle.read(upToCount: 65_536), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func wifiAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if LANTransferValidation.isPrivateIPv4(value) { addresses.insert(value) }
        }
        return addresses.sorted()
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                let timeout = DispatchWorkItem { [weak self] in self?.stopOnQueue(reason: "无法启动局域网服务，请检查 Wi-Fi 连接。") }
                startupTimeout = timeout
                queue.asyncAfter(deadline: .now() + 10, execute: timeout)
                listener.start(queue: queue)
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue(reason: nil) } }

    func cancel(fileID: String) {
        queue.async { [self] in
            files.removeValue(forKey: fileID)
            Array(clients.values).filter { $0.fileID == fileID }.forEach { $0.close() }
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let port = listener.port else { stopOnQueue(reason: "无法取得局域网端口。"); return }
            ready = true
            startupTimeout?.cancel()
            startupTimeout = nil
            let pending = continuation
            continuation = nil
            pending?.resume(returning: port.rawValue)
            let timer = DispatchWorkItem { [weak self] in self?.stopOnQueue(reason: "局域网传输已过期，请重新发送。") }
            expirationTimer = timer
            queue.asyncAfter(deadline: .now() + max(0, expiration.timeIntervalSinceNow), execute: timer)
        case .failed(let error): stopOnQueue(reason: "局域网服务已中断：\(error.localizedDescription)")
        case .cancelled: stopOnQueue(reason: "局域网服务已停止。")
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < 4, Date() < expiration else { connection.cancel(); return }
        let id = UUID()
        let client = LANHTTPClient(connection: connection, queue: queue, token: token, expiration: expiration,
                                   lookup: { [weak self] id in self?.files[id] },
                                   closed: { [weak self] in self?.clients.removeValue(forKey: id) })
        clients[id] = client
        client.start()
    }

    private func stopOnQueue(reason: String?) {
        guard !stopped else { return }
        stopped = true
        startupTimeout?.cancel()
        expirationTimer?.cancel()
        startupTimeout = nil
        expirationTimer = nil
        listener.cancel()
        Array(clients.values).forEach { $0.close() }
        clients.removeAll()
        files.removeAll()
        token = ""
        let pending = continuation
        continuation = nil
        let failure: Error = reason.map { lanServerError($0) as Error } ?? CancellationError()
        pending?.resume(throwing: failure)
        if ready, let reason { onStopped?(reason) }
    }
}

private final class LANHTTPClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var token: String
    private let expiration: Date
    private let lookup: (String) -> LANPreparedFile?
    private let closed: () -> Void
    private var header = Data()
    private var timeout: DispatchWorkItem?
    private var handle: FileHandle?
    private var remaining: Int64 = 0
    private var isClosed = false
    private(set) var fileID: String?

    init(connection: NWConnection, queue: DispatchQueue, token: String, expiration: Date,
         lookup: @escaping (String) -> LANPreparedFile?, closed: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.expiration = expiration
        self.lookup = lookup
        self.closed = closed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        armTimeout()
        receiveHeader()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        timeout?.cancel()
        timeout = nil
        try? handle?.close()
        handle = nil
        token = ""
        header.removeAll()
        connection.cancel()
        closed()
    }

    private func armTimeout() {
        timeout?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        timeout = timer
        queue.asyncAfter(deadline: .now() + 20, execute: timer)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self, !self.isClosed else { return }
            if let data { self.header.append(data) }
            if self.header.count > 16_384 { self.respondError(431); return }
            if let end = self.header.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == self.header.endIndex else { self.respondError(400); return }
                self.processHeader()
            } else if error != nil || complete { self.close() }
            else { self.receiveHeader() }
        }
    }

    private func processHeader() {
        do {
            let request = try LANHTTPRequest(header: header)
            header.removeAll()
            guard request.method == "GET" else { throw LANHTTPFailure(status: 405) }
            guard constantTimeEquals(request.headers["authorization"] ?? "", "Bearer " + token) else { throw LANHTTPFailure(status: 401) }
            guard Date() < expiration else { throw LANHTTPFailure(status: 410) }
            guard let id = request.fileID, let file = lookup(id) else { throw LANHTTPFailure(status: 404) }
            fileID = id
            let attributes = try LANFileAttributes.read(file.url)
            guard attributes.isRegularFile, attributes.byteCount == file.metadata.byteCount,
                  attributes.modificationDate == file.modificationDate else { throw LANHTTPFailure(status: 409) }
            let range: LANHTTPByteRange
            do { range = try LANHTTPByteRange.resolve(request.headers["range"], size: file.metadata.byteCount) }
            catch { respondError(416, extra: "Content-Range: bytes */\(file.metadata.byteCount)\r\n"); return }
            let input = try FileHandle(forReadingFrom: file.url)
            handle = input
            try input.seek(toOffset: UInt64(range.offset))
            remaining = range.length
            var response = "HTTP/1.1 \(range.isPartial ? "206 Partial Content" : "200 OK")\r\n"
            response += "Content-Length: \(range.length)\r\nContent-Type: \(file.metadata.fileName.lowercased().hasSuffix(".mp3") ? "audio/mpeg" : "audio/flac")\r\n"
            response += "Accept-Ranges: bytes\r\nETag: \"\(file.metadata.sha256)\"\r\nCache-Control: no-store\r\nConnection: close\r\n"
            if range.isPartial { response += "Content-Range: bytes \(range.offset)-\(range.offset + range.length - 1)/\(file.metadata.byteCount)\r\n" }
            response += "\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, !self.isClosed else { return }
                if error != nil { self.close() } else { self.sendNextChunk() }
            })
        } catch let error as LANHTTPFailure { respondError(error.status) }
        catch { respondError(500) }
    }

    private func sendNextChunk() {
        guard !isClosed else { return }
        guard Date() < expiration else { close(); return }
        guard remaining > 0 else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }
        do {
            guard let handle, let data = try handle.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else { close(); return }
            remaining -= Int64(data.count)
            armTimeout()
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.isClosed else { return }
                if error != nil { self.close() } else { self.sendNextChunk() }
            })
        } catch { close() }
    }

    private func respondError(_ status: Int, extra: String = "") {
        guard !isClosed else { return }
        let titles = [400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                      409: "Conflict", 410: "Gone", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        let allow = status == 405 ? "Allow: GET\r\n" : ""
        let response = "HTTP/1.1 \(status) \(titles[status] ?? "Error")\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\(allow)\(extra)\r\n"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
