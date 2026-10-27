import AVFoundation
import Foundation

/// Developer-only decoding probe. Compile this standalone executable for a
/// simulator SDK, then invoke it with `simctl spawn` and one or more audio paths.
/// It reads PCM frames and creates an AVAudioPlayer; it never activates an audio
/// session, prepares an output device, or plays sound.
@main
struct AudioDecodeProbe {
    static func main() {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data("Usage: AudioDecodeProbe /absolute/path/to/audio [another-audio ...]\n".utf8))
            exit(2)
        }
        var failed = false
        for path in paths {
            do {
                let url = URL(fileURLWithPath: path)
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                guard file.length > 0, format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                    throw ProbeError.invalidStream
                }
                let capacity = AVAudioFrameCount(min(4_096, file.length))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                    throw ProbeError.cannotAllocateBuffer
                }
                try file.read(into: buffer, frameCount: capacity)
                guard buffer.frameLength > 0 else { throw ProbeError.noDecodedFrames }
                let player = try AVAudioPlayer(contentsOf: url)
                guard player.duration.isFinite, player.duration > 0, player.numberOfChannels > 0 else {
                    throw ProbeError.invalidPlayer
                }
                let codec = file.fileFormat.streamDescription.pointee.mFormatID
                print("DECODE_PASS \(url.lastPathComponent): rate=\(format.sampleRate) channels=\(format.channelCount) frames=\(buffer.frameLength) duration=\(player.duration) codec=\(String(format: "0x%08X", codec))")
            } catch {
                failed = true
                FileHandle.standardError.write(Data("DECODE_FAIL \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)\n".utf8))
            }
        }
        if failed { exit(1) }
    }

    private enum ProbeError: String, LocalizedError {
        case invalidStream, cannotAllocateBuffer, noDecodedFrames, invalidPlayer
        var errorDescription: String? { rawValue }
    }
}
