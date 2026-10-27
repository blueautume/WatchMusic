import Foundation

@main
struct LANReceiptPolicyTests {
    static var assertions = 0
    static let fileID = UUID().uuidString
    static let sessionID = UUID().uuidString
    static let bytes: Int64 = 4_096

    static func event(kind: LANTransferEvent.Kind = .stored,
                      file: String = fileID, session: String = sessionID,
                      completed: Int64 = bytes, total: Int64 = bytes) -> LANTransferEvent {
        LANTransferEvent(sessionID: session, fileID: file, kind: kind,
                         completedBytes: completed, totalBytes: total, message: nil)
    }

    static func accepts(_ event: LANTransferEvent, state: TransferRecordState,
                        record: String = fileID, session: String? = sessionID,
                        total: Int64 = bytes) -> Bool {
        LANReceiptPolicy.acceptsStored(event, recordID: record, sessionID: session,
                                       totalBytes: total, state: state)
    }

    static func confirms(_ event: LANTransferEvent, state: TransferRecordState = .queued,
                         active: Bool = true) -> Bool {
        LANReceiptPolicy.confirmsActiveSession(event, recordID: fileID, sessionID: sessionID,
                                               totalBytes: bytes, state: state,
                                               belongsToActiveSession: active)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        for state in [TransferRecordState.queued, .awaitingReceipt, .failed, .cancelled] {
            expect(accepts(event(), state: state), "Committed save fact wins for \(state.rawValue)")
        }
        expect(!accepts(event(), state: .stored), "Duplicate stored receipt is idempotent")
        expect(!accepts(event(), state: .outdated), "Old save cannot certify changed content")
        for kind in [LANTransferEvent.Kind.progress, .failed, .cancelled] {
            expect(!accepts(event(kind: kind), state: .cancelled), "Only stored can correct cancellation")
        }
        expect(!accepts(event(file: UUID().uuidString), state: .cancelled), "Another file cannot correct cancellation")
        expect(!accepts(event(session: UUID().uuidString), state: .cancelled), "Another session cannot correct cancellation")
        expect(!accepts(event(), state: .cancelled, record: UUID().uuidString), "Historical receipt cannot update a retry record")
        expect(!accepts(event(), state: .cancelled, session: nil), "A missing persisted session is not a binding")
        expect(!accepts(event(completed: bytes - 1), state: .cancelled), "Partial bytes cannot claim stored")
        expect(!accepts(event(completed: bytes + 1), state: .cancelled), "Over-counted bytes cannot claim stored")
        expect(!accepts(event(total: bytes + 1), state: .cancelled), "A changed manifest total is rejected")
        expect(!accepts(event(completed: 0, total: 0), state: .cancelled, total: 0), "Empty transfers cannot claim stored")

        expect(confirms(event()), "A first stored receipt confirms the active handshake before any reply or progress")
        expect(confirms(event(), state: .cancelled), "A committed cancellation race still proves active acceptance")
        expect(!confirms(event(), active: false), "A historical receipt never confirms a new active session")
        expect(!confirms(event(completed: bytes - 1)), "Malformed stored events do not suppress handshake timeouts")
        expect(!confirms(event(session: UUID().uuidString)), "Wrong-session events do not suppress handshake timeouts")
        expect(confirms(event(kind: .progress, completed: 0)), "A bound initial progress event proves acceptance")
        expect(confirms(event(kind: .failed, completed: 0)), "A receiver-side file failure proves acceptance")
        expect(!confirms(event(kind: .progress, completed: -1)), "Negative progress cannot confirm acceptance")
        expect(!confirms(event(kind: .progress), state: .cancelled), "Stale progress cannot revive cancellation")

        for state in [TransferRecordState.queued, .awaitingReceipt, .stored, .failed, .cancelled, .outdated] {
            let decoded = try JSONDecoder().decode(TransferRecordState.self, from: Data(("\"" + state.rawValue + "\"").utf8))
            expect(decoded == state, "Existing persisted state raw values remain compatible")
        }
        print("PASS: \(assertions) LAN save-receipt and handshake policy assertions")
    }
}
