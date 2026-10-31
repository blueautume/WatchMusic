import Foundation

enum PlaybackMode: String, Codable, CaseIterable {
    case sequential, repeatAll, repeatOne, shuffle
    var title: String {
        switch self {
        case .sequential: return L10n.text("顺序播放")
        case .repeatAll: return L10n.text("列表循环")
        case .repeatOne: return L10n.text("单曲循环")
        case .shuffle: return L10n.text("随机播放")
        }
    }
    var symbol: String {
        switch self {
        case .sequential: return "list.bullet"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
}

enum PlaybackQueueLogic {
    static func nextIndex(current: Int, count: Int, mode: PlaybackMode, completed: Bool) -> Int? {
        guard count > 0, (0..<count).contains(current) else { return nil }
        if mode == .shuffle {
            guard count > 1 else { return current }
            let offset = Int.random(in: 1..<count)
            return (current + offset) % count
        }
        if completed && mode == .repeatOne { return current }
        if completed && mode == .sequential && current == count - 1 { return nil }
        return (current + 1) % count
    }
    static func previousIndex(current: Int, count: Int) -> Int? {
        guard count > 0, (0..<count).contains(current) else { return nil }
        return (current - 1 + count) % count
    }
}
