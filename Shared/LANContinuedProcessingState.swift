import Foundation

/// A submission isn't a background execution grant. Keep the two states separate,
/// and reject callbacks from a queue that has already finished or been replaced.
struct LANContinuedProcessingState {
    enum Phase: Equatable {
        case idle
        case requesting(String)
        case running(String)
    }

    private(set) var phase: Phase = .idle

    var identifier: String? {
        switch phase {
        case .idle: return nil
        case .requesting(let value), .running(let value): return value
        }
    }

    var canRunInBackground: Bool {
        if case .running = phase { return true }
        return false
    }

    mutating func request(identifier: String, isForeground: Bool, isSupported: Bool, isRegistered: Bool) -> Bool {
        guard isForeground, isSupported, isRegistered, phase == .idle else { return false }
        phase = .requesting(identifier)
        return true
    }

    mutating func grant(identifier: String) -> Bool {
        guard phase == .requesting(identifier) else { return false }
        phase = .running(identifier)
        return true
    }

    mutating func interrupt(identifier: String) -> Bool {
        guard self.identifier == identifier else { return false }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func finish() -> String? {
        let previous = identifier
        phase = .idle
        return previous
    }
}

/// Downloaded bytes represent 99% of the work; Watch's validated, atomic save
/// receipts represent the last 1%. Receiving all bytes must not finish the job.
struct LANContinuedProcessingProgress: Equatable {
    let totalUnitCount: Int64
    let completedUnitCount: Int64

    init(completedBytes: Int64, totalBytes: Int64, completedFiles: Int, totalFiles: Int) {
        guard totalBytes > 0, totalFiles > 0 else {
            totalUnitCount = 1
            completedUnitCount = 0
            return
        }
        totalUnitCount = 10_000
        let bytes = min(max(0, completedBytes), totalBytes)
        let files = min(max(0, completedFiles), totalFiles)
        if bytes == totalBytes && files == totalFiles {
            completedUnitCount = totalUnitCount
        } else {
            let fraction = Double(bytes) / Double(totalBytes) * 0.99 + Double(files) / Double(totalFiles) * 0.01
            completedUnitCount = min(totalUnitCount - 1, Int64((fraction * Double(totalUnitCount)).rounded(.down)))
        }
    }
}
