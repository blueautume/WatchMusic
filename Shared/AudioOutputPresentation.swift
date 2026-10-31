import Foundation

/// A value snapshot of currentRoute.outputs, never a list of merely discoverable
/// or paired devices. Built-in playback is not an external-device connection.
struct AudioOutputPort: Equatable {
    enum Kind {
        case builtIn, headphones, bluetooth, airPlay, carAudio, other
    }

    let kind: Kind
    let name: String
}

struct AudioOutputPresentation: Equatable {
    let isConnected: Bool
    let symbol: String
    let deviceName: String?

    static let disconnected = AudioOutputPresentation(isConnected: false, symbol: "airplayaudio", deviceName: nil)

    init(isConnected: Bool, symbol: String, deviceName: String?) {
        self.isConnected = isConnected
        self.symbol = symbol
        self.deviceName = deviceName
    }

    init(ports: [AudioOutputPort]) {
        let external = ports.filter { $0.kind != .builtIn }
        guard !external.isEmpty else {
            self = .disconnected
            return
        }
        let names = external.map(\.name).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let symbols = external.map(Self.deviceSymbol)
        // Mixed or unidentified routes retain the route-picker symbol. A
        // Bluetooth/AirPlay protocol by itself does not identify the device.
        let firstSymbol = symbols[0]
        let symbol = symbols.allSatisfy { $0 == firstSymbol } ? firstSymbol : "airplayaudio"
        self.init(isConnected: true, symbol: symbol, deviceName: names.isEmpty ? nil : names.joined(separator: " · "))
    }

    private static func deviceSymbol(_ port: AudioOutputPort) -> String {
        let name = port.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        func hasWord(_ word: String) -> Bool {
            // Device owners' names may directly precede the brand in Chinese.
            // ASCII boundaries still reject names such as "NotAirPods".
            let token = NSRegularExpression.escapedPattern(for: word)
            return name.range(of: "(?<![a-z0-9])" + token + "(?![a-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil
        }
        switch port.kind {
        case .headphones:
            return "headphones"
        case .bluetooth:
            // Names are only a recognition hint. Renamed or unfamiliar devices
            // keep the generic symbol rather than being guessed as headphones.
            let headphoneWords: Set<String> = ["airpods", "powerbeats", "headphones", "headset"]
            let beatsModels: Set<String> = ["fit", "solo", "studio", "flex", "ep", "pro"]
            let speakerWords: Set<String> = ["speaker", "speakers", "soundbar", "pill"]
            guard !speakerWords.contains(where: { hasWord($0) }), !name.contains("音箱"), !name.contains("扬声器") else {
                return "airplayaudio"
            }
            if headphoneWords.contains(where: { hasWord($0) }) || name.contains("耳机")
                || (hasWord("beats") && beatsModels.contains(where: { hasWord($0) })) {
                return "headphones"
            }
        case .airPlay:
            if hasWord("homepod") {
                return hasWord("mini") ? "homepodmini" : "homepod"
            }
        case .carAudio:
            return "car.fill"
        case .builtIn, .other:
            break
        }
        return "airplayaudio"
    }
}
