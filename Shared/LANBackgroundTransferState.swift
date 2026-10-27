import Foundation

/// Persisted application bookkeeping, independent of URLSession's daemon-owned
/// download files. Completed data stays recoverable until its save is recorded.
struct LANBackgroundTransferState: Codable {
    enum Phase: String, Codable {
        case queued, downloading, paused, validating, stored, failed, cancelled
        var isPending: Bool { self == .queued || self == .downloading || self == .paused || self == .validating }
    }

    struct Item: Codable {
        var phase: Phase = .queued
        var receivedBytes: Int64 = 0
        var taskIdentifier: Int?
        var stagingName: String?
        var addressIndex = 0
        var controlRevision: Int64? = nil
    }

    let offer: LANTransferOffer
    let acceptedAt: Date
    let allowsLoopbackForTesting: Bool
    var items: [String: Item]

    init(offer: LANTransferOffer, acceptedAt: Date = Date(), allowsLoopbackForTesting: Bool = false) {
        self.offer = offer
        self.acceptedAt = acceptedAt
        self.allowsLoopbackForTesting = allowsLoopbackForTesting
        let paused = Set(offer.pausedFileIDs ?? [])
        items = Dictionary(uniqueKeysWithValues: offer.files.map { file in
            var item = Item()
            if paused.contains(file.id) { item.phase = .paused }
            return (file.id, item)
        })
    }

    var pendingFileIDs: Set<String> { Set(items.filter { $0.value.phase.isPending }.map(\.key)) }
    var isFinished: Bool { pendingFileIDs.isEmpty }

    func canStartRequest(at date: Date) -> Bool { offer.expiresAt > date }

    func validateForRestoration(allowLoopback: Bool) throws {
        // Expiry prevents new requests, not delivery of data the system already
        // downloaded. Validate against the original acceptance time on restore.
        try LANTransferValidation.validate(offer, now: acceptedAt, allowLoopback: allowLoopback)
        guard items.count == offer.files.count, Set(items.keys) == Set(offer.files.map(\.id)) else { throw invalidState() }
        for file in offer.files {
            guard let item = items[file.id], item.receivedBytes >= 0, item.receivedBytes <= file.byteCount,
                  item.addressIndex >= 0, item.addressIndex < offer.baseURLs.count,
                  item.taskIdentifier.map({ $0 > 0 }) ?? true,
                  item.controlRevision.map({ $0 >= 0 }) ?? true else { throw invalidState() }
            if let name = item.stagingName {
                guard Self.isStagingName(name), item.phase == .validating || item.phase == .paused,
                      item.taskIdentifier == nil, item.receivedBytes == file.byteCount else { throw invalidState() }
            } else if item.phase == .validating { throw invalidState() }
            if !item.phase.isPending, item.taskIdentifier != nil { throw invalidState() }
            if item.phase == .stored, item.receivedBytes != file.byteCount { throw invalidState() }
        }
    }

    static func isStagingName(_ name: String) -> Bool {
        name.hasSuffix(".download") && UUID(uuidString: String(name.dropLast(9))) != nil
    }

    static func taskDescription(sessionID: String, fileID: String) -> String { sessionID + "|" + fileID }

    static func taskIdentity(_ description: String?) -> (sessionID: String, fileID: String)? {
        guard let description else { return nil }
        let parts = description.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              UUID(uuidString: String(parts[1])) != nil else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    func file(for fileID: String) -> LANTransferFile? { offer.files.first { $0.id == fileID } }

    @discardableResult mutating func recordProgress(fileID: String, bytes: Int64) -> Bool {
        guard let file = file(for: fileID), var item = items[fileID],
              item.phase == .queued || item.phase == .downloading || item.phase == .paused,
              bytes >= item.receivedBytes, bytes <= file.byteCount else { return false }
        item.receivedBytes = bytes
        if item.phase != .paused { item.phase = .downloading }
        items[fileID] = item
        return true
    }

    @discardableResult mutating func recordDownloaded(fileID: String, stagingName: String) -> Bool {
        guard let file = file(for: fileID), var item = items[fileID],
              item.phase == .queued || item.phase == .downloading || item.phase == .paused,
              Self.isStagingName(stagingName) else { return false }
        if item.phase != .paused { item.phase = .validating }
        item.receivedBytes = file.byteCount
        item.taskIdentifier = nil
        item.stagingName = stagingName
        items[fileID] = item
        return true
    }

    /// The outbox is written before a terminal manifest update. Fold its durable
    /// outcome back into a stale manifest after a crash in that narrow window.
    @discardableResult mutating func applyTerminalReceipt(_ event: LANTransferEvent) -> Bool {
        guard event.sessionID == offer.sessionID, let file = file(for: event.fileID),
              event.totalBytes == file.byteCount, event.completedBytes >= 0,
              event.completedBytes <= file.byteCount,
              var item = items[event.fileID], item.phase.isPending else { return false }
        switch event.kind {
        case .stored:
            guard event.completedBytes == file.byteCount else { return false }
            item.phase = .stored
        case .failed: item.phase = .failed
        case .cancelled: item.phase = .cancelled
        case .progress, .paused, .resumed: return false
        }
        item.receivedBytes = event.completedBytes
        item.taskIdentifier = nil
        item.stagingName = nil
        items[event.fileID] = item
        return true
    }

    @discardableResult mutating func recordTerminal(fileID: String, kind: LANTransferEvent.Kind) -> Bool {
        guard var item = items[fileID], item.phase.isPending else { return false }
        switch kind {
        case .stored:
            guard item.phase == .validating, let file = file(for: fileID) else { return false }
            item.phase = .stored
            item.receivedBytes = file.byteCount
        case .failed: item.phase = .failed
        case .cancelled: item.phase = .cancelled
        case .progress, .paused, .resumed: return false
        }
        item.taskIdentifier = nil
        item.stagingName = nil
        items[fileID] = item
        return true
    }

    /// Revisions make duplicated/reordered WatchConnectivity controls idempotent.
    /// Validation already in flight is a save operation, not pausable network work.
    @discardableResult mutating func setPaused(fileID: String, paused: Bool, revision: Int64) -> Bool {
        guard revision > 0, var item = items[fileID], item.phase.isPending,
              item.phase != .validating, revision > (item.controlRevision ?? 0) else { return false }
        item.controlRevision = revision
        if paused { item.phase = .paused }
        else { item.phase = item.stagingName == nil ? .downloading : .validating }
        items[fileID] = item
        return true
    }

    private func invalidState() -> NSError {
        NSError(domain: "LANBackgroundTransferState", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "局域网后台接收记录无效，请重新发送。"])
    }
}

/// Receipt lifetime is independent of the currently displayed transfer batch.
/// An acknowledgement can only remove that exact session/file pair.
struct LANBackgroundReceiptOutbox: Codable {
    private var receipts: [String: LANTransferEvent] = [:]
    var events: [LANTransferEvent] { Array(receipts.values) }
    var count: Int { receipts.count }

    init() {}

    init(from decoder: Decoder) throws {
        let decoded = try decoder.singleValueContainer().decode([String: LANTransferEvent].self)
        receipts = decoded.filter { key, event in
            key == Self.key(sessionID: event.sessionID, fileID: event.fileID) &&
            UUID(uuidString: event.sessionID) != nil && UUID(uuidString: event.fileID) != nil &&
            event.kind.isTerminal && event.totalBytes > 0 &&
            event.completedBytes >= 0 && event.completedBytes <= event.totalBytes &&
            (event.kind != .stored || event.completedBytes == event.totalBytes)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(receipts)
    }

    mutating func insert(_ event: LANTransferEvent) {
        guard event.kind.isTerminal else { return }
        receipts[Self.key(sessionID: event.sessionID, fileID: event.fileID)] = event
    }

    func contains(sessionID: String, fileID: String) -> Bool {
        receipts[Self.key(sessionID: sessionID, fileID: fileID)] != nil
    }

    mutating func acknowledge(sessionID: String, fileID: String) {
        receipts.removeValue(forKey: Self.key(sessionID: sessionID, fileID: fileID))
    }

    private static func key(sessionID: String, fileID: String) -> String { sessionID + "/" + fileID }
}

/// Finishing a background wake waits for delegate delivery and the validation
/// work it started, but never for unrelated tasks still owned by the daemon.
struct LANBackgroundDeliveryBarrier {
    private(set) var eventsDrained = false
    private var validationKeys = Set<String>()
    private var isReconciling = false

    var canComplete: Bool { eventsDrained && validationKeys.isEmpty && !isReconciling }
    mutating func beginDelivery() { eventsDrained = false }
    mutating func didFinishEvents() { eventsDrained = true }
    mutating func beginReconciliation() { isReconciling = true }
    mutating func finishReconciliation() { isReconciling = false }
    mutating func beginValidation(_ key: String) -> Bool { validationKeys.insert(key).inserted }
    mutating func finishValidation(_ key: String) { validationKeys.remove(key) }
}
