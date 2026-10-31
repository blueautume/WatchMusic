import Foundation

/// Runs as a real bundle executable so production Bundle.main lookups are tested.
@main
struct LocalizationProbe {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let expectedLanguage = CommandLine.arguments[1]
        let english = expectedLanguage == "en"
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw Failure(message: message) }
        }
        func table(_ language: String) throws -> [String: String] {
            let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                      subdirectory: nil, localization: language)!
            return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
        }
        let sources = try [table("en"), table("zh-Hans")]
        let name = "我的歌曲 50% %@ 🎵.flac"
        try check(Bundle.main.bundleURL.pathExtension == "bundle", "Probe must run inside the temporary bundle")
        try check(Bundle.main.preferredLocalizations.first == expectedLanguage, "Real bundle language selection and fallback")
        try check(L10n.isEnglish == english, "Legal-document language follows bundle language")
        try check(L10n.text("已暂停") == (english ? "Paused" : "已暂停"), "Static runtime text is localized")
        try check(L10n.text("随身音乐") == (english ? "WatchMusic" : "随身音乐"), "Product name is localized")
        try check(L10n.message("Saved to Watch") == L10n.text("已保存到手表"), "Ambiguous old translations choose the canonical saved state consistently")
        try check(L10n.format("%@ 的封面", name) == (english ? "Artwork for \(name)" : "\(name) 的封面"), "Object formatting preserves Unicode and literal percent signs")
        try check(L10n.format("剩余约 %lld 小时 %lld 分钟", Int64(2), Int64(15)) ==
                  (english ? "About 2 hr 15 min remaining" : "剩余约 2 小时 15 分钟"), "Integer formatting uses both arguments")
        try check(L10n.text("unregistered-user-value") == "unregistered-user-value", "Unknown text uses a safe fallback")
        try check(L10n.message("").isEmpty, "Empty peer state stays empty")
        for userContent in [name, "我的歌曲：现场版", "Song: live recording", "雨后：已暂停🎵", "50% complete"] {
            try check(L10n.message(userContent) == userContent, "Unknown user content must remain unchanged: \(userContent)")
        }
        for source in sources {
            for key in ["已暂停", "已保存到手表", "等待两端 App 打开后继续", "等待手表 App 打开"] {
                // A few Chinese synonyms deliberately share one English value
                // (for example, the stored-state and saved-receipt messages).
                let equivalentKeys = sources[0].filter { $0.value == sources[0][key] }.map(\.key)
                let accepted = Set(equivalentKeys.map { L10n.text($0) })
                try check(accepted.contains(L10n.message(source[key]!)), "Stored and peer \(key) messages follow the receiving app language")
            }
            let receivedKey = "已收到：%@"
            let received = String(format: source[receivedKey]!, name)
            try check(L10n.message(received) == L10n.format(receivedKey, name), "Transfer receipt translates and preserves a user filename")
            for title in ["播放", "Paused", "已暂停", ""] {
                let receipt = String(format: source[receivedKey]!, title)
                try check(L10n.message(receipt) == L10n.format(receivedKey, title),
                          "A song named after a known UI key must remain user content: \(title)")
            }
            let downloadKey = "局域网下载失败（HTTP %@）。"
            let download = String(format: source[downloadKey]!, "404")
            try check(L10n.message(download) == L10n.format(downloadKey, "404"), "Peer HTTP error template translates")
            let remainingKey = "剩余约 %lld 小时 %lld 分钟"
            let remaining = String(format: source[remainingKey]!, Int64(2), Int64(15))
            try check(L10n.message(remaining) == L10n.format(remainingKey, Int64(2), Int64(15)), "Historical numeric template translates")
            let errorKey = "无法播放此文件：%@"
            let detailKey = "音频无效或时长为零"
            let nested = String(format: source[errorKey]!, source[detailKey]!)
            try check(L10n.message(nested) == L10n.format(errorKey, L10n.text(detailKey)), "Nested application errors translate across device languages")
            try check(L10n.message(received) == L10n.format(receivedKey, name), "Repeated conversions stay stable after caching")
        }
        // A phone and Watch using different languages can contribute records in
        // either order; localization must follow this process, not the last peer.
        try check(L10n.message(sources[0]["已暂停"]!) == L10n.message(sources[1]["已暂停"]!), "Mixed-language peer histories have one display language")
        print("PASS: \(assertions) localization assertions (\(expectedLanguage), preferences \(UserDefaults.standard.array(forKey: "AppleLanguages") ?? []))")
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
