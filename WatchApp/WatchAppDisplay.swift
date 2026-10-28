import CoreMotion
import SwiftUI
import WatchKit

/// One display state for every app screen. It never controls playback or transfers.
@MainActor
final class WatchAppDisplay: ObservableObject {
    @Published private(set) var orientation = WatchTransferOrientation.portrait
    @Published private(set) var isCharging = false
    @Published private(set) var batteryPercentage: Int?

    private let motion = CMMotionManager()
    private var tracker = WatchTransferOrientationTracker()
    private var batteryTimer: Timer?
    private var motionTimer: Timer?
    private var originalBatteryMonitoring: Bool?
    private var isForeground = false

    func start(foreground: Bool) {
        guard originalBatteryMonitoring == nil else { setForeground(foreground); return }
        let device = WKInterfaceDevice.current()
        originalBatteryMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        isForeground = foreground
        refreshPower()
        updateBatteryTimer()
    }

    func stop() {
        batteryTimer?.invalidate(); batteryTimer = nil
        stopMotion()
        if let originalBatteryMonitoring {
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = originalBatteryMonitoring
        }
        originalBatteryMonitoring = nil
        isForeground = false
    }

    func setForeground(_ value: Bool) {
        isForeground = value
        guard originalBatteryMonitoring != nil else { return }
        refreshPower()
        updateBatteryTimer()
    }

    private func updateBatteryTimer() {
        guard isForeground else {
            batteryTimer?.invalidate(); batteryTimer = nil
            return
        }
        guard batteryTimer == nil else { return }
        // WatchKit exposes battery values without a change notification. Keep
        // polling only while the app is visible, including during scrolling.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPower() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func refreshPower() {
        let device = WKInterfaceDevice.current()
        let state = device.batteryState
        var charging = state == .charging || state == .full
        let level = device.batteryLevel
        var percentage: Int? = level.isFinite && (0...1).contains(level)
            ? Int((level * 100).rounded()) : nil
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-preview-charging") { charging = true }
        if arguments.contains("-preview-unplugged") { charging = false }
        if let flag = arguments.firstIndex(of: "-preview-battery"), arguments.indices.contains(flag + 1) {
            percentage = Int(arguments[flag + 1]).flatMap { (0...100).contains($0) ? $0 : nil }
        }
        #endif
        if batteryPercentage != percentage { batteryPercentage = percentage }
        if isCharging != charging {
            isCharging = charging
            tracker.reset()
        }
        if !charging, orientation != .portrait { orientation = .portrait }
        updateMotion()
    }

    private func updateMotion() {
        guard isForeground, isCharging else { stopMotion(); return }
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let preview: WatchTransferOrientation? = arguments.contains("-preview-landscape") ? .landscapeRight
            : (arguments.contains("-preview-landscape-left") ? .landscapeLeft
                : (arguments.contains("-preview-upside-down") ? .upsideDown : nil))
        if let preview {
            stopMotion()
            if orientation != preview { orientation = preview }
            return
        }
        #endif
        guard motion.isDeviceMotionAvailable else { stopMotion(); return }
        guard motionTimer == nil else { return }
        motion.deviceMotionUpdateInterval = 0.25
        motion.startDeviceMotionUpdates()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleGravity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func sampleGravity() {
        guard isForeground, isCharging, let gravity = motion.deviceMotion?.gravity else { return }
        // Motion axes are hardware-fixed; left-crown UI is upside down.
        let sign = WKInterfaceDevice.current().crownOrientation == .left ? -1.0 : 1.0
        let next = tracker.update(gravityX: gravity.x * sign,
                                  gravityY: gravity.y * sign, gravityZ: gravity.z)
        if orientation != next { orientation = next }
    }

    private func stopMotion() {
        motionTimer?.invalidate(); motionTimer = nil
        motion.stopDeviceMotionUpdates()
        tracker = WatchTransferOrientationTracker(orientation: orientation)
    }
}
