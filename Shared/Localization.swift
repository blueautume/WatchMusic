import Foundation

/// Both targets use the same vocabulary. File names, metadata and protocol IDs
/// are deliberately left untouched; only app-owned copy is localized.
enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static var isEnglish: Bool {
        !(Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }

    /// Transfer history and older peers contain human-readable messages rather
    /// than language-neutral IDs. Translate at the display boundary so changing
    /// language never requires rewriting a queue or changing its wire format.
    static func message(_ value: String) -> String {
        localizedMessage(value, depth: 0)
    }

    private static func localizedMessage(_ value: String, depth: Int) -> String {
        guard !value.isEmpty else { return value }
        guard depth < 4 else { return value }
        if let key = messageKeys[value] { return text(key) }
        let direct = text(value)
        if direct != value { return direct }
        let cacheKey = value as NSString
        if let cached = messageCache.object(forKey: cacheKey) { return cached as String }
        for template in messageTemplates {
            guard let translated = template.translate(value, localizeArgument: {
                localizedMessage($0, depth: depth + 1)
            }) else { continue }
            messageCache.setObject(translated as NSString, forKey: cacheKey)
            return translated
        }
        // System errors and user-provided text may have no app translation.
        return value
    }

    private static let messageCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()

    private static let tables: [[String: String]] = ["zh-Hans", "en"].compactMap { language in
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                        subdirectory: nil, localization: language),
              let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String] else { return nil }
        return table
    }

    private static let messageKeys: [String: String] = {
        var keys: [String: String] = [:]
        for table in tables {
            for (key, value) in table.sorted(by: {
                $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count < $1.key.count
            }) where !key.contains("%") {
                if keys[value] == nil { keys[value] = key }
            }
        }
        return keys
    }()

    private static let messageTemplates: [MessageTemplate] = tables.flatMap { table in
        table.compactMap { key, value in
            MessageTemplate(key: key, source: value)
        }
    }.sorted { $0.specificity > $1.specificity }

    private struct MessageTemplate {
        private static let placeholder = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:ll|l)?[@diufg]"#)
        let key: String
        let pattern: NSRegularExpression
        let specificity: Int

        init?(key: String, source: String) {
            let range = NSRange(source.startIndex..., in: source)
            let tokens = Self.placeholder.matches(in: source, range: range)
            guard !tokens.isEmpty else { return nil }
            let literal = Self.placeholder.stringByReplacingMatches(in: source, range: range, withTemplate: "")
            guard literal.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
            self.key = key
            specificity = source.count - tokens.reduce(0) { $0 + $1.range.length }
            var expression = "^"
            var cursor = source.startIndex
            for token in tokens {
                guard let tokenRange = Range(token.range, in: source) else { return nil }
                expression += NSRegularExpression.escapedPattern(for: String(source[cursor..<tokenRange.lowerBound]))
                expression += source[tokenRange].hasSuffix("@") ? "(.*?)" : "(-?[0-9]+(?:[.,][0-9]+)?)"
                cursor = tokenRange.upperBound
            }
            expression += NSRegularExpression.escapedPattern(for: String(source[cursor...])) + "$"
            guard let pattern = try? NSRegularExpression(pattern: expression, options: [.dotMatchesLineSeparators]) else { return nil }
            self.pattern = pattern
        }

        func translate(_ source: String, localizeArgument: (String) -> String) -> String? {
            guard let match = pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
            let destination = L10n.text(key)
            let tokens = Self.placeholder.matches(in: destination, range: NSRange(destination.startIndex..., in: destination))
            var result = ""
            var cursor = destination.startIndex
            for (index, token) in tokens.enumerated() {
                guard let tokenRange = Range(token.range, in: destination) else { return nil }
                let argumentIndex = Range(token.range(at: 1), in: destination)
                    .flatMap { Int(destination[$0]) } ?? (index + 1)
                guard argumentIndex < match.numberOfRanges,
                      let argumentRange = Range(match.range(at: argumentIndex), in: source) else { return nil }
                let argument = String(source[argumentRange])
                result += destination[cursor..<tokenRange.lowerBound]
                // Only error wrappers contain another app message. Arguments
                // in receipts, artwork labels and folder actions are user data.
                let containsNestedError = key.contains("失败") || key.hasPrefix("无法")
                    || ["局域网服务已中断：%@", "手机连接暂不可用：%@", "未收到手表确认：%@",
                        "已删除，但%@", "已移动，但%@"].contains(key)
                result += containsNestedError && destination[tokenRange].hasSuffix("@")
                    ? localizeArgument(argument) : argument
                cursor = tokenRange.upperBound
            }
            result += destination[cursor...]
            return result
        }
    }
}
