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
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.lihao.WatchMusic.orientation"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var tracker = WatchTransferOrientationTracker()
    private var batteryTimer: Timer?
    private var motionGeneration: UInt64 = 0
    private var activeMotionGeneration: UInt64?
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
        guard activeMotionGeneration == nil else { return }
        motionGeneration &+= 1
        let generation = motionGeneration
        activeMotionGeneration = generation
        motion.deviceMotionUpdateInterval = 0.25
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] sample, error in
            // Move plain values between executors, rather than Core Motion's
            // framework objects. A transient gap interrupts the debounce window.
            let gravity = error == nil ? sample?.gravity : nil
            let value = gravity.map { WatchGravitySample(x: $0.x, y: $0.y, z: $0.z) }
            Task { @MainActor [weak self] in
                self?.applyMotionSample(value, generation: generation)
            }
        }
    }

    private func applyMotionSample(_ gravity: WatchGravitySample?, generation: UInt64) {
        guard isForeground, isCharging, activeMotionGeneration == generation else { return }
        guard let gravity else {
            tracker = WatchTransferOrientationTracker(orientation: orientation)
            return
        }
        // Motion axes are hardware-fixed; left-crown UI is upside down.
        let sign = WKInterfaceDevice.current().crownOrientation == .left ? -1.0 : 1.0
        let next = tracker.update(gravityX: gravity.x * sign,
                                  gravityY: gravity.y * sign, gravityZ: gravity.z)
        if orientation != next { orientation = next }
    }

    private func stopMotion() {
        guard activeMotionGeneration != nil else { return }
        // Already-enqueued MainActor tasks may outlive stopDeviceMotionUpdates.
        activeMotionGeneration = nil
        motion.stopDeviceMotionUpdates()
        tracker = WatchTransferOrientationTracker(orientation: orientation)
    }
}

private struct WatchGravitySample: Sendable {
    let x: Double
    let y: Double
    let z: Double
}
