import Foundation

struct LocalAudioMetadata: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: Data?
}

/// Bounded fallback for formats that AVAsset does not expose consistently on
/// watchOS. It reads only FLAC metadata blocks or a leading ID3v2.3/v2.4 tag.
/// Unknown frames are skipped; no network resources or audio frames are read.
/// Layout references:
/// https://www.rfc-editor.org/rfc/rfc9639.html#section-8
/// https://id3.org/id3v2.3.0
/// https://id3.org/id3v2.4.0-structure
/// https://id3.org/id3v2.4.0-frames
/// Compressed/encrypted ID3 frames and ID3v2.2 are intentionally not decoded.
enum AudioMetadataReader {
    static let maximumMetadataBytes = 32 * 1_024 * 1_024
    static let maximumArtworkBytes = 20 * 1_024 * 1_024
    private static let maximumTextBytes = 64 * 1_024
    private static let maximumEntries = 4_096

    static func read(from url: URL) -> LocalAudioMetadata {
        var result = Accumulator()
        do {
            let stream = try FileStream(url: url)
            defer { try? stream.handle.close() }
            let magic = try stream.read(4)
            if magic == Data("fLaC".utf8) {
                try readFLAC(stream, result: &result)
            } else if magic.prefix(3) == Data("ID3".utf8) {
                try stream.seek(to: 0)
                try readID3(stream, result: &result)
            }
        } catch {
            // Malformed optional metadata must not prevent audio playback.
        }
        return result.value
    }

    private struct Accumulator {
        var value = LocalAudioMetadata()
        var pictureType: UInt32?
        mutating func storePicture(_ data: Data, type: UInt32) {
            guard !data.isEmpty, data.count <= maximumArtworkBytes,
                  value.artworkData == nil || (type == 3 && pictureType != 3) else { return }
            value.artworkData = data
            pictureType = type
        }
    }

    private static func readFLAC(_ stream: FileStream, result: inout Accumulator) throws {
        var consumed = 4
        for blockIndex in 0..<maximumEntries {
            let header = try stream.read(4)
            let last = header[0] & 0x80 != 0
            let type = header[0] & 0x7f
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard type != 127, length <= maximumMetadataBytes - consumed - 4 else { return }
            if blockIndex == 0, type != 0 || length != 34 { return }
            consumed += length + 4
            var section = try FileSection(stream: stream, count: length)
            do {
                switch type {
                case 4: try readVorbisComments(&section, result: &result)
                case 6: try readFLACPicture(&section, result: &result)
                default: break
                }
            } catch {
                // A broken optional block does not hide later valid artwork.
            }
            try section.skip(section.remaining)
            if last { return }
        }
    }

    private static func readVorbisComments<R: MetadataCursor>(_ cursor: inout R, result: inout Accumulator) throws {
        let vendorLength = try readUInt32(&cursor, littleEndian: true)
        try cursor.skip(try checkedCount(vendorLength, maximum: cursor.remaining))
        let commentCount = try readUInt32(&cursor, littleEndian: true)
        guard commentCount <= UInt32(maximumEntries) else { return }
        for _ in 0..<commentCount {
            let rawLength = try readUInt32(&cursor, littleEndian: true)
            let length = try checkedCount(rawLength, maximum: cursor.remaining)
            guard length <= maximumTextBytes + 256 else { try cursor.skip(length); continue }
            let bytes = try cursor.read(length)
            guard let comment = String(data: bytes, encoding: .utf8), let separator = comment.firstIndex(of: "=") else { continue }
            let key = normalizedKey(String(comment[..<separator]))
            let value = String(comment[comment.index(after: separator)...])
            switch key {
            case "TITLE": if result.value.title == nil { result.value.title = cleaned(value, maximum: maximumTextBytes) }
            case "ARTIST": if result.value.artist == nil { result.value.artist = cleaned(value, maximum: maximumTextBytes) }
            case "ALBUM": if result.value.album == nil { result.value.album = cleaned(value, maximum: maximumTextBytes) }
            default: break
            }
        }
    }

    private static func readFLACPicture<R: MetadataCursor>(_ cursor: inout R, result: inout Accumulator) throws {
        let type = try readUInt32(&cursor)
        let mimeLength = try checkedCount(readUInt32(&cursor), maximum: cursor.remaining)
        guard mimeLength <= 256 else { return }
        let mimeData = try cursor.read(mimeLength)
        let mime = String(data: mimeData, encoding: .ascii) ?? ""
        let descriptionLength = try checkedCount(readUInt32(&cursor), maximum: cursor.remaining)
        try cursor.skip(descriptionLength)
        // Width, height, bits per pixel, and indexed-color count are each u32.
        try cursor.skip(16)
        let dataLength = try checkedCount(readUInt32(&cursor), maximum: cursor.remaining)
        guard mime != "-->", dataLength > 0, dataLength <= maximumArtworkBytes,
              result.value.artworkData == nil || (type == 3 && result.pictureType != 3) else { return }
        result.storePicture(try cursor.read(dataLength), type: type)
    }

    private static func readID3(_ stream: FileStream, result: inout Accumulator) throws {
        let header = try stream.read(10)
        let version = header[3]
        guard version == 3 || version == 4, header[4] != 0xff,
              let length = synchsafe(header.subdata(in: 6..<10)), length <= maximumMetadataBytes else { return }
        if version == 3, header[5] & 0x1f != 0 { return }
        if version == 4, header[5] & 0x0f != 0 { return }
        var section = try FileSection(stream: stream, count: length)
        if version == 3, header[5] & 0x80 != 0 {
            // ID3v2.3 uses tag-wide unsynchronisation. Read bounded chunks into
            // only the decoded metadata buffer; never retain a second raw tag.
            var decoded = Data()
            decoded.reserveCapacity(length)
            var previousFF = false
            while section.remaining > 0 {
                let chunk = try section.read(min(section.remaining, 16_384))
                for byte in chunk {
                    if previousFF && byte == 0 { previousFF = false; continue }
                    decoded.append(byte)
                    previousFF = byte == 0xff
                }
            }
            var cursor = DataCursor(decoded)
            try readID3Frames(&cursor, version: version, tagFlags: header[5], result: &result)
        } else {
            try readID3Frames(&section, version: version, tagFlags: header[5], result: &result)
        }
    }

    private static func readID3Frames<R: MetadataCursor>(_ cursor: inout R, version: UInt8, tagFlags: UInt8, result: inout Accumulator) throws {
        if tagFlags & 0x40 != 0 {
            let raw = try cursor.read(4)
            if version == 3 {
                let size = bigEndian(raw)
                try cursor.skip(try checkedCount(size, maximum: cursor.remaining))
            } else {
                guard let size = synchsafe(raw), size >= 6 else { return }
                try cursor.skip(size - 4)
            }
        }
        let known = Set(["TIT2", "TPE1", "TALB", "APIC"])
        for _ in 0..<maximumEntries {
            guard cursor.remaining >= 10 else { return }
            let header = try cursor.read(10)
            let idBytes = header.prefix(4)
            if idBytes.allSatisfy({ $0 == 0 }) { return }
            guard idBytes.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
                  let identifier = String(data: idBytes, encoding: .ascii) else { return }
            let length: Int
            if version == 4 {
                guard let value = synchsafe(header.subdata(in: 4..<8)) else { return }
                length = value
            } else { length = try checkedCount(bigEndian(header.subdata(in: 4..<8)), maximum: cursor.remaining) }
            guard length <= cursor.remaining else { return }
            if length == 0 { continue }
            let flags = header[9]
            let unsupported = version == 3 ? flags & 0xdf != 0 : flags & 0xbc != 0
            let budget = identifier == "APIC" ? maximumArtworkBytes + maximumTextBytes : maximumTextBytes + 1
            guard known.contains(identifier), !unsupported, length <= budget else { try cursor.skip(length); continue }
            var data = try cursor.read(length)
            if version == 4, flags & 0x02 != 0 || tagFlags & 0x80 != 0 { data = deunsynchronised(data) }
            var body = DataCursor(data)
            if (version == 3 && flags & 0x20 != 0) || (version == 4 && flags & 0x40 != 0) { try body.skip(1) }
            if version == 4, flags & 0x01 != 0 {
                guard synchsafe(try body.read(4)) != nil else { continue }
            }
            try? parseID3Frame(identifier, cursor: &body, result: &result)
        }
    }

    private static func parseID3Frame(_ identifier: String, cursor: inout DataCursor, result: inout Accumulator) throws {
        guard cursor.remaining > 0 else { return }
        let encoding = try cursor.read(1)[0]
        guard encoding <= 3 else { return }
        switch identifier {
        case "TIT2", "TPE1", "TALB":
            guard cursor.remaining <= maximumTextBytes else { return }
            let text = cleaned(decodeText(try cursor.read(cursor.remaining), encoding: encoding), maximum: maximumTextBytes)
            if identifier == "TIT2", result.value.title == nil { result.value.title = text }
            if identifier == "TPE1", result.value.artist == nil { result.value.artist = text }
            if identifier == "TALB", result.value.album == nil { result.value.album = text }
        case "APIC":
            guard let mimeBytes = try readTerminated(&cursor, encoding: 0, maximum: 256), cursor.remaining >= 1 else { return }
            let mime = String(data: mimeBytes, encoding: .isoLatin1) ?? ""
            let type = UInt32(try cursor.read(1)[0])
            guard mime != "-->", try readTerminated(&cursor, encoding: encoding, maximum: maximumTextBytes) != nil,
                  cursor.remaining > 0, cursor.remaining <= maximumArtworkBytes else { return }
            result.storePicture(try cursor.read(cursor.remaining), type: type)
        default: break
        }
    }

    private static func readTerminated(_ cursor: inout DataCursor, encoding: UInt8, maximum: Int) throws -> Data? {
        let unit = encoding == 1 || encoding == 2 ? 2 : 1
        let start = cursor.position
        var end = start
        while end + unit <= cursor.data.count, end - start <= maximum {
            let zero = cursor.data[end] == 0 && (unit == 1 || cursor.data[end + 1] == 0)
            if zero {
                cursor.position = end + unit
                return cursor.data.subdata(in: start..<end)
            }
            end += unit
        }
        return nil
    }

    private static func decodeText(_ data: Data, encoding: UInt8, fallbackEndian: String.Encoding? = nil) -> String? {
        let value: String?
        switch encoding {
        case 0: value = String(data: data, encoding: .isoLatin1)
        case 1:
            if let order = utf16Endian(data) { value = String(data: data.dropFirst(2), encoding: order) }
            else { value = String(data: data, encoding: fallbackEndian ?? .utf16LittleEndian) }
        case 2: value = String(data: data, encoding: .utf16BigEndian)
        case 3: value = String(data: data, encoding: .utf8)
        default: return nil
        }
        return value?.trimmingCharacters(in: CharacterSet(charactersIn: "\0\u{feff}"))
    }

    private static func utf16Endian(_ data: Data) -> String.Encoding? {
        if data.starts(with: [0xff, 0xfe]) { return .utf16LittleEndian }
        if data.starts(with: [0xfe, 0xff]) { return .utf16BigEndian }
        return nil
    }

    private static func cleaned(_ value: String?, maximum: Int) -> String? {
        guard let value, value.utf8.count <= maximum else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\u{feff}")))
        return text.isEmpty ? nil : text.replacingOccurrences(of: "\0", with: "\n")
    }

    private static func normalizedKey(_ value: String) -> String {
        value.uppercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" && $0 != "\0" && $0 != "\u{feff}" }
    }

    private static func deunsynchronised(_ data: Data) -> Data {
        var result = Data(); result.reserveCapacity(data.count)
        var previousFF = false
        for byte in data {
            if previousFF && byte == 0 { previousFF = false; continue }
            result.append(byte); previousFF = byte == 0xff
        }
        return result
    }

    private static func synchsafe(_ bytes: Data) -> Int? {
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 128 }) else { return nil }
        return bytes.reduce(0) { $0 << 7 | Int($1) }
    }

    private static func bigEndian(_ bytes: Data) -> UInt32 { bytes.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func checkedCount(_ value: UInt32, maximum: Int) throws -> Int {
        guard let count = Int(exactly: value), count <= maximum else { throw MetadataError.invalidLength }
        return count
    }

    private static func readUInt32<R: MetadataCursor>(_ cursor: inout R, littleEndian: Bool = false) throws -> UInt32 {
        let bytes = try cursor.read(4)
        return littleEndian ? bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) } : bigEndian(bytes)
    }

    private protocol MetadataCursor {
        var remaining: Int { get }
        mutating func read(_ count: Int) throws -> Data
        mutating func skip(_ count: Int) throws
    }

    private final class FileStream {
        let handle: FileHandle
        let size: UInt64
        var position: UInt64 = 0
        init(url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            do { size = try handle.seekToEnd(); try handle.seek(toOffset: 0) }
            catch { try? handle.close(); throw error }
        }
        func read(_ count: Int) throws -> Data {
            guard count >= 0, count <= maximumMetadataBytes,
                  position <= size, UInt64(count) <= size - position else { throw MetadataError.invalidLength }
            var data = Data(); data.reserveCapacity(count)
            while data.count < count {
                guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { throw MetadataError.truncated }
                data.append(chunk)
            }
            position += UInt64(count)
            return data
        }
        func seek(to next: UInt64) throws {
            guard next <= size else { throw MetadataError.invalidLength }
            try handle.seek(toOffset: next); position = next
        }
    }

    private struct FileSection: MetadataCursor {
        let stream: FileStream
        let end: UInt64
        init(stream: FileStream, count: Int) throws {
            guard count >= 0, stream.position <= stream.size, UInt64(count) <= stream.size - stream.position else { throw MetadataError.invalidLength }
            self.stream = stream; end = stream.position + UInt64(count)
        }
        var remaining: Int { Int(end - stream.position) }
        mutating func read(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw MetadataError.invalidLength }
            return try stream.read(count)
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= remaining else { throw MetadataError.invalidLength }
            try stream.seek(to: stream.position + UInt64(count))
        }
    }

    private struct DataCursor: MetadataCursor {
        let data: Data
        var position = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - position }
        mutating func read(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw MetadataError.invalidLength }
            let result = data.subdata(in: position..<(position + count)); position += count; return result
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= remaining else { throw MetadataError.invalidLength }
            position += count
        }
    }

    private enum MetadataError: Error { case invalidLength, truncated }
}
