import Foundation

/// A request to cancel cannot undo a save that the watch already committed.
/// Late save facts are scoped to one immutable historical file/session binding.
enum LANReceiptPolicy {
    static func acceptsStored(_ event: LANTransferEvent, recordID: String,
                              sessionID: String?, totalBytes: Int64,
                              state: TransferRecordState) -> Bool {
        guard event.kind == .stored, event.fileID == recordID,
              sessionID == event.sessionID, totalBytes > 0,
              event.totalBytes == totalBytes, event.completedBytes == totalBytes else { return false }
        switch state {
        case .queued, .paused, .awaitingReceipt, .failed, .cancelled: return true
        case .stored, .outdated: return false
        }
    }

    static func confirmsActiveSession(_ event: LANTransferEvent, recordID: String,
                                      sessionID: String?, totalBytes: Int64,
                                      state: TransferRecordState, belongsToActiveSession: Bool) -> Bool {
        guard belongsToActiveSession else { return false }
        if event.kind == .stored {
            return acceptsStored(event, recordID: recordID, sessionID: sessionID,
                                 totalBytes: totalBytes, state: state)
        }
        return state.isPending && event.fileID == recordID && sessionID == event.sessionID &&
            totalBytes > 0 && event.totalBytes == totalBytes &&
            event.completedBytes >= 0 && event.completedBytes <= totalBytes
    }
}
