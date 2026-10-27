import Foundation
import ImageIO

/// Decode thumbnails without expanding full-size photos in the watch's memory.
enum ArtworkDecoder {
    static let maximumInputBytes = 20 * 1_024 * 1_024
    #if os(watchOS)
    static let preferredPixelSize = 512
    #else
    static let preferredPixelSize = 1_024
    #endif

    static func thumbnailData(from data: Data, maximumPixelSize: Int = preferredPixelSize) -> Data? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    static func thumbnailData(from url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumInputBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return thumbnailData(from: data)
    }
}
