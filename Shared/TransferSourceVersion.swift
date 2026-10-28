import Darwin
import Foundation

/// A cheap, uncached filesystem version for validating a previously computed
/// digest. Content equality still requires SHA-256 and the watch's confirmation.
/// Change time also invalidates in-place writes that restore the old mtime.
struct TransferSourceVersion: Codable, Equatable, Sendable {
    let byteCount: Int64
    let deviceID: Int64
    let inode: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    static func read(_ url: URL) throws -> TransferSourceVersion {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        var info = stat()
        var failure: Int32 = EINVAL
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let result = Darwin.lstat(path, &info)
            if result != 0 { failure = errno }
            return result
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: url.path])
        }
        // lstat deliberately rejects the link itself rather than following it.
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return TransferSourceVersion(byteCount: Int64(info.st_size), deviceID: Int64(info.st_dev),
                                     inode: UInt64(info.st_ino),
                                     modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                                     modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                                     changeSeconds: Int64(info.st_ctimespec.tv_sec),
                                     changeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
