import Foundation

@main
struct AudioFileFormatTests {
    private static var assertions = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let cases: [(String, AudioFileFormat?)] = [
            ("song.mp3", .mp3), ("song.MP3", .mp3), ("song.Mp3", .mp3),
            ("song.flac", .flac), ("song.FLAC", .flac), ("song.FlAc", .flac),
            ("晚风散步.flac", .flac), ("recording.mix.v2.FLAC", .flac),
            ("no-extension", nil), (".flac", nil), ("song.wav", nil),
            ("song.m4a", nil), ("song.aac", nil), ("song.flac.txt", nil),
            ("song.mp3.backup", nil), ("folder.flac/song", nil)
        ]
        for (path, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(path)")
            expect(AudioFileFormat.format(for: url) == expected, "recognize extension: \(path)")
            expect(AudioFileFormat.supports(url) == (expected != nil), "supported formats only: \(path)")
        }
        expect(Set(AudioFileFormat.allCases.map(\.rawValue)) == Set(["mp3", "flac"]), "public import formats remain MP3 and FLAC")
        expect(AudioFileFormat.mp3.displayName == "MP3", "MP3 display name")
        expect(AudioFileFormat.flac.displayName == "FLAC", "FLAC display name")

        // A rename must preserve the source format; it must never label FLAC bytes
        // with an MP3 extension, which was the old import/rename implementation.
        for (source, expected) in [("Original.FLAC", AudioFileFormat.flac), ("Original.MP3", .mp3)] {
            let format = AudioFileFormat.format(for: URL(fileURLWithPath: source))
            expect(format == expected, "recognize source format before rename")
            guard let format else { continue }
            let renamed = AudioFileFormat.fileName(stem: "Renamed song", format: format)
            expect(renamed == "Renamed song.\(expected.rawValue)", "rename preserves \(expected.displayName)")
            expect(AudioFileFormat.format(for: URL(fileURLWithPath: renamed)) == expected, "renamed file remains importable")
        }

        let stems = ["A song", "夜航", "artist - track", "mix.v2", "with spaces", "🎵 local song"]
        for format in AudioFileFormat.allCases {
            for stem in stems {
                for duplicate in [1, 2, 3, 10] {
                    let filename = AudioFileFormat.fileName(stem: stem, format: format, duplicateIndex: duplicate)
                    let expected = duplicate == 1 ? "\(stem).\(format.rawValue)" : "\(stem) (\(duplicate)).\(format.rawValue)"
                    expect(filename == expected, "duplicate naming preserves title and format")
                    let url = URL(fileURLWithPath: "/tmp/Music/\(filename)")
                    expect(url.pathExtension == format.rawValue, "canonical extension after duplicate import")
                    expect(AudioFileFormat.format(for: url) == format, "duplicate remains playable in its original format")
                }
            }
        }
        expect(AudioFileFormat.fileName(stem: "Same title", format: .mp3) != AudioFileFormat.fileName(stem: "Same title", format: .flac), "same-title MP3 and FLAC can coexist")
        print("PASS: \(assertions) audio format assertions")
    }
}
