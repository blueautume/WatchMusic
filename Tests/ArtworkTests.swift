import CoreGraphics
import Foundation
import ImageIO

@main
struct ArtworkTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    }

    static func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TestError.context }
        context.setFillColor(CGColor(red: 0.1, green: 0.15, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.45, blue: 0.18, alpha: 0.65))
        context.fillEllipse(in: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
        guard let image = context.makeImage() else { throw TestError.image }
        return image
    }

    static func encode(_ image: CGImage, as type: String, orientation: Int = 1) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw TestError.destination }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92,
                                                       kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestError.encode }
        return data as Data
    }

    static func inspect(_ data: Data, maximum: Int, expectedLandscape: Bool? = nil) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { expect(false, "thumbnail decodes"); return }
        expect(CGImageSourceGetType(source) as String? == "public.jpeg", "normalized output uses JPEG")
        expect(image.width > 0 && image.height > 0, "positive thumbnail dimensions")
        expect(max(image.width, image.height) <= maximum, "thumbnail respects \(maximum) pixel bound")
        if let landscape = expectedLandscape { expect(landscape ? image.width > image.height : image.width < image.height, "orientation preserved") }
    }

    static func main() throws {
        expect(ArtworkDecoder.maximumInputBytes == 20 * 1_024 * 1_024, "20 MiB input contract")
        expect(ArtworkDecoder.thumbnailData(from: Data()) == nil, "empty input rejected")
        expect(ArtworkDecoder.thumbnailData(from: Data("not an image".utf8)) == nil, "invalid input rejected")
        expect(ArtworkDecoder.thumbnailData(from: Data([0xff, 0xd8, 0xff])) == nil, "truncated JPEG rejected")
        let large = try makeImage(width: 4_096, height: 3_072)
        let jpeg = try encode(large, as: "public.jpeg")
        let png = try encode(large, as: "public.png")
        expect(jpeg.count < ArtworkDecoder.maximumInputBytes && png.count < ArtworkDecoder.maximumInputBytes, "test fixtures are within input budget")
        for (name, input) in [("JPEG", jpeg), ("PNG", png)] {
            guard let result = ArtworkDecoder.thumbnailData(from: input) else { throw TestError.thumbnail(name) }
            expect(result != input, "large \(name) actually resampled")
            inspect(result, maximum: 1_024, expectedLandscape: true)
            guard let small = ArtworkDecoder.thumbnailData(from: input, maximumPixelSize: 512) else { throw TestError.thumbnail(name) }
            inspect(small, maximum: 512, expectedLandscape: true)
        }
        let oriented = try encode(large, as: "public.jpeg", orientation: 6)
        guard let rotated = ArtworkDecoder.thumbnailData(from: oriented) else { throw TestError.thumbnail("oriented JPEG") }
        inspect(rotated, maximum: 1_024, expectedLandscape: false)
        let smallInput = try encode(makeImage(width: 64, height: 48), as: "public.png")
        guard let smallResult = ArtworkDecoder.thumbnailData(from: smallInput) else { throw TestError.thumbnail("small PNG") }
        inspect(smallResult, maximum: 1_024, expectedLandscape: true)
        if let source = CGImageSourceCreateWithData(smallResult as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            expect(image.width <= 64 && image.height <= 48, "small cover is not upscaled")
        }
        var oversizedJPEG = jpeg
        oversizedJPEG.append(Data(repeating: 0, count: ArtworkDecoder.maximumInputBytes + 1 - oversizedJPEG.count))
        expect(ArtworkDecoder.thumbnailData(from: oversizedJPEG) == nil, "valid JPEG header above 20 MiB is rejected before decoding")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cover = root.appendingPathComponent("cover.png")
        try png.write(to: cover)
        guard let fromURL = ArtworkDecoder.thumbnailData(from: cover) else { throw TestError.thumbnail("file URL") }
        inspect(fromURL, maximum: 1_024, expectedLandscape: true)
        let invalid = root.appendingPathComponent("invalid.jpg")
        try Data("invalid".utf8).write(to: invalid)
        expect(ArtworkDecoder.thumbnailData(from: invalid) == nil, "invalid file URL rejected")
        expect(ArtworkDecoder.thumbnailData(from: root.appendingPathComponent("missing.jpg")) == nil, "missing file URL rejected")
        let huge = root.appendingPathComponent("huge.jpg")
        try oversizedJPEG.write(to: huge)
        expect(ArtworkDecoder.thumbnailData(from: huge) == nil, "file URL enforces 20 MiB bound")
        print("PASS: \(assertions) artwork assertions")
    }
    private enum TestError: Error { case context, image, destination, encode, thumbnail(String) }
}
