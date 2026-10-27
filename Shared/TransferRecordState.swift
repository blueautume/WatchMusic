import Foundation

enum TransferRecordState: String, Codable {
    case queued, awaitingReceipt, stored, failed, cancelled, outdated
    var title: String {
        switch self {
        case .queued: return "等待传输"
        case .awaitingReceipt: return "等待手表确认"
        case .stored: return "已保存到手表"
        case .failed: return "传输失败"
        case .cancelled: return "已取消"
        case .outdated: return "本地已更新，需重新发送"
        }
    }
    var symbol: String {
        switch self {
        case .queued: return "arrow.up.circle.fill"
        case .awaitingReceipt: return "clock.fill"
        case .stored: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .outdated: return "arrow.triangle.2.circlepath"
        }
    }
    var isPending: Bool { self == .queued || self == .awaitingReceipt }
}
