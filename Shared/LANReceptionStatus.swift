import Foundation

/// A read-only observation of one file, identified independently of its name
/// or its position among concurrently running system download tasks.
struct LANReceptionFileStatus: Identifiable, Equatable {
    let id: String
    let fileName: String
    let completedBytes: Int64
    let totalBytes: Int64
    let phase: LANBackgroundTransferState.Phase

    init(id: String, fileName: String, completedBytes: Int64, totalBytes: Int64,
         phase: LANBackgroundTransferState.Phase) {
        self.id = id
        self.fileName = fileName
        self.totalBytes = max(0, totalBytes)
        self.completedBytes = min(max(0, completedBytes), self.totalBytes)
        self.phase = phase
    }

    var progress: Double { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0 }
    var isPending: Bool { phase.isPending }
}

/// A complete batch snapshot in manifest order. Received bytes include partial
/// failed/cancelled files; only the explicit stored phase confirms a saved file.
struct LANReceptionStatus: Equatable {
    let files: [LANReceptionFileStatus]
    let focusedFileID: String?
    private let legacyFileIndex: Int?
    private let legacyFileCount: Int?

    init(files: [LANReceptionFileStatus], focusedFileID: String? = nil) {
        self.files = files
        self.focusedFileID = focusedFileID
        legacyFileIndex = nil
        legacyFileCount = nil
    }

    init(state: LANBackgroundTransferState) {
        let files = state.offer.files.map { file in
            let item = state.items[file.id] ?? LANBackgroundTransferState.Item()
            return LANReceptionFileStatus(id: file.id, fileName: file.fileName,
                completedBytes: item.receivedBytes, totalBytes: file.byteCount, phase: item.phase)
        }
        self.init(files: files, focusedFileID: state.nextRunnableFileID() ??
            state.offer.files.first(where: { state.items[$0.id]?.phase == .paused })?.id)
    }

    var batchTotalBytes: Int64 { Self.sum(files.map(\.totalBytes)) }
    var batchReceivedBytes: Int64 { Self.sum(files.map(\.completedBytes)) }
    var batchProgress: Double {
        batchTotalBytes > 0 ? Double(batchReceivedBytes) / Double(batchTotalBytes) : 0
    }
    var storedCount: Int { count(.stored) }
    var failedCount: Int { count(.failed) }
    var cancelledCount: Int { count(.cancelled) }
    var queuedCount: Int { count(.queued) }
    var downloadingCount: Int { count(.downloading) }
    var pausedCount: Int { count(.paused) }
    var validatingCount: Int { count(.validating) }
    var pendingCount: Int { files.filter(\.isPending).count }
    var finishedCount: Int { storedCount + failedCount + cancelledCount }
    var isBatchPaused: Bool { pendingCount > 0 && pendingCount == pausedCount }
    var isFinished: Bool { pendingCount == 0 }
    var allStored: Bool { !files.isEmpty && storedCount == files.count }

    var focusedFile: LANReceptionFileStatus? {
        if let file = files.first(where: { $0.id == focusedFileID }) { return file }
        for phase in [LANBackgroundTransferState.Phase.validating, .downloading, .queued, .paused] {
            if let file = files.first(where: { $0.phase == phase }) { return file }
        }
        return files.first
    }

    // Compatibility for the existing single-file preview and lifecycle probe.
    // New batch UI should use files and batch* rather than these focused values.
    var fileName: String { focusedFile?.fileName ?? "" }
    var completedBytes: Int64 { focusedFile?.completedBytes ?? 0 }
    var totalBytes: Int64 { focusedFile?.totalBytes ?? 0 }
    var fileIndex: Int {
        legacyFileIndex ?? focusedFile.flatMap { file in files.firstIndex(where: { $0.id == file.id }).map { $0 + 1 } } ?? 0
    }
    var fileCount: Int { legacyFileCount ?? files.count }
    var isSaving: Bool { focusedFile?.phase == .validating }
    var isPaused: Bool { focusedFile?.phase == .paused }

    /// An old preview provides only one file's data. Retain its displayed batch
    /// position without inventing successful results or unknown song rows.
    init(fileName: String, completedBytes: Int64, totalBytes: Int64, fileIndex: Int,
         fileCount: Int, isSaving: Bool, isPaused: Bool = false) {
        let phase: LANBackgroundTransferState.Phase = isPaused ? .paused :
            (isSaving ? .validating : (completedBytes > 0 ? .downloading : .queued))
        let file = LANReceptionFileStatus(id: "legacy-reception-preview", fileName: fileName,
            completedBytes: completedBytes, totalBytes: totalBytes, phase: phase)
        files = [file]
        focusedFileID = file.id
        legacyFileIndex = fileIndex
        legacyFileCount = fileCount
    }

    private func count(_ phase: LANBackgroundTransferState.Phase) -> Int { files.filter { $0.phase == phase }.count }

    private static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }
}
