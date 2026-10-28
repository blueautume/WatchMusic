import Foundation

/// The temporary download service accepts one bounded HTTP request per connection.
struct LANHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]

    init(header: Data) throws {
        guard header.count <= 16_384 else { throw LANHTTPFailure(status: 431) }
        guard let text = String(data: header, encoding: .utf8), text.hasSuffix("\r\n\r\n"),
              !text.contains("\0") else { throw LANHTTPFailure(status: 400) }
        let lines = String(decoding: header.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first, lines.count <= 101 else { throw LANHTTPFailure(status: 400) }
        let requestLine = first.components(separatedBy: " ")
        guard requestLine.count == 3, !requestLine[0].isEmpty,
              requestLine[1].hasPrefix("/"), !requestLine[1].contains(where: { $0.isWhitespace }),
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else { throw LANHTTPFailure(status: 400) }
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { throw LANHTTPFailure(status: 400) }
            let name = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.utf8.allSatisfy({ $0 >= 32 || $0 == 9 }), parsed[name] == nil else { throw LANHTTPFailure(status: 400) }
            parsed[name] = value
        }
        guard requestLine[2] != "HTTP/1.1" || parsed["host"]?.isEmpty == false,
              parsed["transfer-encoding"] == nil,
              parsed["content-length"] == nil || parsed["content-length"] == "0" else { throw LANHTTPFailure(status: 400) }
        method = requestLine[0]
        target = requestLine[1]
        headers = parsed
    }

    var fileID: String? {
        let prefix = "/v1/files/"
        guard target.hasPrefix(prefix) else { return nil }
        let id = String(target.dropFirst(prefix.count))
        return UUID(uuidString: id) != nil ? id : nil
    }
}

struct LANHTTPByteRange: Equatable {
    let offset: Int64
    let length: Int64
    let isPartial: Bool

    static func resolve(_ header: String?, size: Int64) throws -> LANHTTPByteRange {
        guard size > 0 else { throw LANHTTPFailure(status: 416) }
        guard let header else { return LANHTTPByteRange(offset: 0, length: size, isPartial: false) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { throw LANHTTPFailure(status: 416) }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        func number(_ value: Substring) -> Int64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(value)
        }
        guard parts.count == 2 else { throw LANHTTPFailure(status: 416) }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]), suffix > 0 else { throw LANHTTPFailure(status: 416) }
            let length = min(size, suffix)
            return LANHTTPByteRange(offset: size - length, length: length, isPartial: true)
        }
        guard let start = number(parts[0]), start < size else { throw LANHTTPFailure(status: 416) }
        let end: Int64
        if parts[1].isEmpty { end = size - 1 }
        else {
            guard let requestedEnd = number(parts[1]), requestedEnd >= start else { throw LANHTTPFailure(status: 416) }
            end = min(size - 1, requestedEnd)
        }
        return LANHTTPByteRange(offset: start, length: end - start + 1, isPartial: true)
    }
}

struct LANHTTPFailure: Error {
    let status: Int
}
