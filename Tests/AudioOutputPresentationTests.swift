import Foundation

@main
struct AudioOutputPresentationTests {
    static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(condition(), message)
        }
        func output(_ kind: AudioOutputPort.Kind, _ name: String) -> AudioOutputPresentation {
            AudioOutputPresentation(ports: [AudioOutputPort(kind: kind, name: name)])
        }
        check(AudioOutputPresentation(ports: []) == .disconnected, "No active output is disconnected")
        for name in ["Apple Watch Speaker", "iPhone", "HomePod", "AirPods"] {
            check(output(.builtIn, name) == .disconnected, "A built-in output is never mistaken for a connected device by its name")
        }
        for name in ["Headphones", "My listening device", "耳机"] {
            let value = output(.headphones, name)
            check(value.isConnected && value.symbol == "headphones", "Explicit headphone ports identify the category even when renamed")
            check(value.deviceName == name, "The device name stays unchanged")
        }
        let airPodsCases = [
            ("AirPods", "airpods"), ("AIRPODS", "airpods"), ("李浩的AirPods", "airpods"),
            ("AirPods 3", "airpods"), ("AirPods 4", "airpods"), ("Max’s AirPods", "airpods"),
            ("Li’s AirPods Pro", "airpodspro"), ("李浩的AirPods Pro", "airpodspro"),
            ("AirPods Pro 2", "airpodspro"), ("AirPodsPro", "airpodspro"),
            ("AIRPODS-PRO", "airpodspro"), ("Max’s AirPods Pro", "airpodspro"),
            ("AirPods Max", "airpodsmax"), ("李浩的AirPods Max", "airpodsmax"),
            ("AirPodsMax", "airpodsmax"), ("Pro’s AirPods Max", "airpodsmax")
        ]
        for (name, symbol) in airPodsCases {
            for kind in [AudioOutputPort.Kind.bluetooth, .headphones] {
                let value = output(kind, name)
                check(value.isConnected && value.symbol == symbol && value.deviceName == name,
                      "AirPods use their own model icon while preserving the route name: \(name)")
            }
        }
        for name in ["Beats Fit Pro", "Powerbeats Pro", "Bluetooth Headset", "蓝牙耳机"] {
            let value = output(.bluetooth, name)
            check(value.isConnected && value.symbol == "headphones", "Recognizable Bluetooth headphones use the headphone symbol: \(name)")
        }
        for name in ["Living Room", "Beats Pill", "AirPods-like speaker", "NotHomePod", "", "WH-1000XM5"] {
            let value = output(.other, name)
            check(value.isConnected && value.symbol == "airplayaudio", "An unknown port is connected without inventing a device category")
        }
        for name in ["Living Room", "Beats Pill", "Wireless Speaker", "My Device", "AirPods-like speaker", "Beats Studio 音箱", "NotAirPods", "NotAirPodsPro", "AirPodsPrototype"] {
            let value = output(.bluetooth, name)
            check(value.isConnected && value.symbol == "airplayaudio", "Bluetooth alone does not imply headphones")
        }
        check(output(.airPlay, "Bedroom HomePod").symbol == "homepod", "Recognizable HomePod uses its own symbol")
        check(output(.airPlay, "HomePod mini").symbol == "homepodmini", "Recognizable HomePod mini uses its own symbol")
        check(output(.airPlay, "客厅HomePod mini").symbol == "homepodmini", "A Chinese room name can precede the product name")
        check(output(.airPlay, "NotHomePod").symbol == "airplayaudio", "Product names must not match inside an unrelated word")
        check(output(.airPlay, "Living Room").symbol == "airplayaudio", "A renamed AirPlay target remains generic")
        check(output(.bluetooth, "HomePod").symbol == "airplayaudio", "A name hint inconsistent with the transport is not a HomePod route")
        check(output(.airPlay, "AirPods Pro").symbol == "airplayaudio", "AirPlay is not treated as a headphone transport")
        check(output(.carAudio, "Car").symbol == "car.fill", "A typed car-audio route uses the car symbol")
        let unknown = output(.other, "")
        check(unknown.isConnected && unknown.deviceName == nil, "An unnamed external output still reports a connection")
        let multiple = AudioOutputPresentation(ports: [.init(kind: .headphones, name: "A"), .init(kind: .airPlay, name: "HomePod")])
        check(multiple.isConnected && multiple.symbol == "airplayaudio" && multiple.deviceName == "A · HomePod", "Mixed routes keep a generic symbol and all endpoint names")
        let builtInAndExternal = AudioOutputPresentation(ports: [.init(kind: .builtIn, name: "Speaker"), .init(kind: .headphones, name: "Headphones")])
        check(builtInAndExternal.symbol == "headphones" && builtInAndExternal.deviceName == "Headphones", "Internal outputs do not obscure an external endpoint")
        check(AudioOutputPresentation(ports: []) == .disconnected, "Removing a route returns the icon and connection to their defaults")
        print("PASS: \(assertions) audio-output connection and device-presentation assertions")
    }
}
