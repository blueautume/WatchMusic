import Foundation

@main
struct AudioMetadataReaderTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        assertions += 1
        do {
            guard try condition() else { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
        } catch { FileHandle.standardError.write(Data("FAIL: \(message): \(error)\n".utf8)); exit(1) }
    }
    static func be(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    static func le(_ value: UInt32) -> Data { Data(be(value).reversed()) }
    static func ss(_ value: Int) -> Data { Data([UInt8((value >> 21) & 127), UInt8((value >> 14) & 127), UInt8((value >> 7) & 127), UInt8(value & 127)]) }
    static func text(_ string: String, encoding: UInt8 = 3) -> Data { Data([encoding]) + Data(string.utf8) }
    static func frame(_ name: String, _ data: Data, version: UInt8 = 4, flags: UInt8 = 0) -> Data {
        Data(name.utf8) + (version == 4 ? ss(data.count) : be(UInt32(data.count))) + Data([0, flags]) + data
    }
    static func tag(_ frames: [Data], version: UInt8 = 4, flags: UInt8 = 0, prefix: Data = Data()) -> Data {
        let body = prefix + frames.reduce(Data(), +)
        return Data("ID3".utf8) + Data([version, 0, flags]) + ss(body.count) + body
    }
    static func uslt(_ string: String, encoding: UInt8 = 3) -> Data {
        Data([encoding]) + Data("eng".utf8) + Data([0]) + Data(string.utf8)
    }
    static func txxx(_ name: String, _ string: String) -> Data { Data([3]) + Data(name.utf8) + Data([0]) + Data(string.utf8) }
    static func apic(_ bytes: Data, type: UInt8 = 3) -> Data { Data([0]) + Data("image/jpeg".utf8) + Data([0, type, 0]) + bytes }
    static func flacBlock(_ type: UInt8, _ data: Data, last: Bool) -> Data {
        let length = data.count
        return Data([type | (last ? 0x80 : 0), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]) + data
    }
    static func flac(_ blocks: [(UInt8, Data)]) -> Data {
        let all: [(UInt8, Data)] = [(0, Data(repeating: 0, count: 34))] + blocks
        return Data("fLaC".utf8) + all.enumerated().reduce(Data()) { $0 + flacBlock($1.element.0, $1.element.1, last: $1.offset == all.count - 1) }
    }
    static func comments(_ strings: [String]) -> Data {
        le(5) + Data("Tests".utf8) + le(UInt32(strings.count)) + strings.reduce(Data()) { $0 + le(UInt32($1.utf8.count)) + Data($1.utf8) }
    }
    static func picture(_ bytes: Data, type: UInt32 = 3) -> Data {
        be(type) + be(10) + Data("image/jpeg".utf8) + be(0) + be(100) + be(100) + be(24) + be(0) + be(UInt32(bytes.count)) + bytes
    }
    static func unsync(_ data: Data) -> Data {
        var output = Data()
        for byte in data { output.append(byte); if byte == 0xff { output.append(0) } }
        return output
    }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("metadata-reader-tests-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var counter = 0
        func read(_ data: Data, extension suffix: String = "mp3") throws -> LocalAudioMetadata {
            counter += 1
            let url = root.appendingPathComponent("fixture-\(counter)." + suffix)
            try data.write(to: url)
            return AudioMetadataReader.read(from: url)
        }
        let lyric = "[00:01.00]第一句\n[00:03.50]Second line\n"
        let front = Data([0xff, 0xd8, 0xff, 0xe0, 5, 6, 0xff, 0xd9])
        let back = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let basic = try read(tag([frame("TIT2", text("歌曲")), frame("TPE1", text("艺术家")), frame("TALB", text("专辑")), frame("USLT", uslt(lyric)), frame("APIC", apic(back, type: 4)), frame("APIC", apic(front)), frame("APIC", apic(back, type: 0))]))
        expect(basic.title == "歌曲" && basic.artist == "艺术家" && basic.album == "专辑", "ID3v2.4 text tags")
        expect(basic.artworkData == front, "ID3 front cover preferred over other pictures")
        let v3 = try read(tag([frame("USLT", uslt("plain lyrics", encoding: 0), version: 3), frame("TIT2", text("Latin song", encoding: 0), version: 3)], version: 3))
        expect(v3.title == "Latin song", "ID3v2.3 ignores unused frames and reads Latin-1 text")
        let utf16BE = try read(tag([frame("TIT2", Data([2]) + "大海".data(using: .utf16BigEndian)!)]))
        expect(utf16BE.title == "大海", "ID3 UTF-16BE without BOM")
        let unknown = try read(tag([frame("XXXX", Data(repeating: 10, count: 8)), frame("USLT", Data([0]), flags: 0x08), frame("TIT2", text("after compressed/encrypted")), frame("USLT", Data([0]), flags: 0x04)]))
        expect(unknown.title == "after compressed/encrypted", "unknown, compressed and encrypted frames safely skipped")
        let grouped = try read(tag([frame("TIT2", Data([8]) + text("grouped"), flags: 0x40)]))
        expect(grouped.title == "grouped", "ID3v2.4 grouping prefix")
        let dli = try read(tag([frame("TIT2", ss(text("length").count) + text("length"), flags: 0x01)]))
        expect(dli.title == "length", "ID3v2.4 data length indicator")
        let v4Unsync = try read(tag([frame("APIC", unsync(apic(front)), flags: 0x02)]))
        expect(v4Unsync.artworkData == front, "ID3v2.4 per-frame unsynchronisation")
        let original = frame("APIC", apic(front), version: 3)
        let stored = unsync(original)
        let v3Unsync = try read(Data("ID3".utf8) + Data([3, 0, 0x80]) + ss(stored.count) + stored)
        expect(v3Unsync.artworkData == front, "ID3v2.3 tag-wide unsynchronisation")
        let ext3 = try read(tag([frame("TIT2", text("extended3", encoding: 0), version: 3)], version: 3, flags: 0x40, prefix: be(6) + Data(repeating: 0, count: 6)))
        let ext4 = try read(tag([frame("TIT2", text("extended4"))], flags: 0x40, prefix: ss(6) + Data([1, 0])))
        expect(ext3.title == "extended3" && ext4.title == "extended4", "version-specific extended header sizes")
        let malformedFrame = try read(tag([frame("USLT", Data([1, 2])), frame("TIT2", text("survives bad USLT"))]))
        expect(malformedFrame.title == "survives bad USLT", "malformed optional frame does not hide later valid frame")
        let flacValue = try read(flac([(4, comments(["TITLE=歌曲", "artist=歌手", "ALBUM=测试", "UNSYNCEDLYRICS=plain", "LYRICS=" + lyric])), (6, picture(back, type: 4)), (6, picture(front)), (6, picture(back, type: 0))]), extension: "flac")
        expect(flacValue.title == "歌曲" && flacValue.artist == "歌手" && flacValue.album == "测试", "FLAC little-endian Vorbis comments")
        expect(flacValue.artworkData == front, "FLAC PICTURE front cover preference")
        let malformedComment = le(UInt32.max) + Data([0, 0, 0, 0])
        let damagedBlock = try read(flac([(4, malformedComment), (6, picture(front))]), extension: "flac")
        expect(damagedBlock.title == nil && damagedBlock.artworkData == front, "bad Vorbis length cannot hide valid following picture")
        let externalPicture = be(3) + be(3) + Data("-->".utf8) + be(0) + Data(repeating: 0, count: 16) + be(20) + Data("https://example.test".utf8)
        let linked = try read(flac([(6, externalPicture)]), extension: "flac")
        expect(linked.artworkData == nil, "linked pictures are never treated as local art or fetched")
        let truncatedPicture = picture(front).dropLast(4)
        let truncated = try read(flac([(6, Data(truncatedPicture))]), extension: "flac")
        expect(truncated.artworkData == nil, "truncated picture payload rejected")
        for data in [Data(), Data("not audio".utf8), Data("ID3".utf8), Data("fLaC".utf8), Data("ID3".utf8) + Data([5, 0, 0, 0, 0, 0, 0])] {
            expect(try read(data) == LocalAudioMetadata(), "empty/unknown/truncated/unsupported headers")
        }
        let invalidTagLength = Data("ID3".utf8) + Data([4, 0, 0, 0x80, 0, 0, 0])
        expect(try read(invalidTagLength) == LocalAudioMetadata(), "non-synchsafe ID3 size rejected")
        let hugeTag = Data("ID3".utf8) + Data([4, 0, 0]) + ss(AudioMetadataReader.maximumMetadataBytes + 1)
        expect(try read(hugeTag) == LocalAudioMetadata(), "over-budget tag rejected without allocation")
        let hugeFrame = Data("ID3".utf8) + Data([3, 0, 0]) + ss(10) + Data("USLT".utf8) + be(UInt32.max) + Data([0, 0])
        expect(try read(hugeFrame) == LocalAudioMetadata(), "overflow/truncated ID3 frame size rejected")
        let completeID3 = tag([frame("TIT2", text("bounded")), frame("USLT", uslt(lyric)), frame("APIC", apic(front))])
        for count in 0..<completeID3.count {
            expect(try read(Data(completeID3.prefix(count))) == LocalAudioMetadata(), "every ID3 truncation remains bounded and rejects incomplete tag")
        }
        let completeFLAC = flac([(4, comments(["TITLE=bounded"])), (6, picture(front))])
        for count in 0..<completeFLAC.count {
            expect(try read(Data(completeFLAC.prefix(count)), extension: "flac").artworkData == nil, "every FLAC picture truncation remains bounded")
        }
        let hugeArt = Data(repeating: 7, count: AudioMetadataReader.maximumArtworkBytes + 1)
        expect(try read(tag([frame("APIC", apic(hugeArt))])).artworkData == nil, "20 MiB picture input bound")
        // A huge sparse audio tail must be irrelevant to metadata parsing. The
        // implementation returns at the final metadata flag, before audio data.
        let sparse = root.appendingPathComponent("sparse.flac")
        try flac([(4, comments(["TITLE=metadata only"]))]).write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 512 * 1_024 * 1_024)
        try handle.close()
        expect(AudioMetadataReader.read(from: sparse).title == "metadata only", "streamed FLAC metadata ignores 512 MiB audio tail")
        for path in CommandLine.arguments.dropFirst() {
            let actual = AudioMetadataReader.read(from: URL(fileURLWithPath: path))
            expect(actual.title != nil && actual.artist != nil, "real fixture title and artist: \(path)")
            expect((actual.artworkData?.count ?? 0) > 0, "real fixture cover art: \(path)")
        }
        print("PASS: \(assertions) bounded audio metadata assertions")
    }
}
