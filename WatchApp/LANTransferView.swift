import CoreMotion
import SwiftUI
import WatchKit

/// Display-only state. Network work remains independent of screen state.
final class WatchTransferDisplay: ObservableObject {
    @Published private(set) var orientation = WatchTransferOrientation.portrait
    @Published private(set) var isCharging = false
    @Published private(set) var isAutomatic = true
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
        updateCharging()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.updateCharging()
        }
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
        updateCharging()
    }

    func useAutomaticOrientation() {
        isAutomatic = true
        tracker = WatchTransferOrientationTracker(orientation: orientation)
        updateMotion()
    }

    func rotate() {
        isAutomatic = false
        stopMotion()
        switch orientation {
        case .portrait: orientation = .landscapeRight
        case .landscapeRight: orientation = .upsideDown
        case .upsideDown: orientation = .landscapeLeft
        case .landscapeLeft: orientation = .portrait
        }
    }

    private func updateCharging() {
        let state = WKInterfaceDevice.current().batteryState
        let charging = state == .charging || state == .full
        if isCharging != charging {
            isCharging = charging
            tracker.reset()
            if !charging { orientation = .portrait; isAutomatic = true }
        }
        updateMotion()
    }

    private func updateMotion() {
        guard isForeground, isCharging, isAutomatic, motion.isDeviceMotionAvailable else {
            stopMotion()
            return
        }
        guard motionTimer == nil else { return }
        motion.deviceMotionUpdateInterval = 0.25
        motion.startDeviceMotionUpdates()
        motionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let gravity = self.motion.deviceMotion?.gravity else { return }
            // Motion axes are hardware-fixed; left-crown UI is upside down.
            let sign = WKInterfaceDevice.current().crownOrientation == .left ? -1.0 : 1.0
            let next = self.tracker.update(gravityX: gravity.x * sign,
                                          gravityY: gravity.y * sign, gravityZ: gravity.z)
            if self.orientation != next { self.orientation = next }
        }
    }

    private func stopMotion() {
        motionTimer?.invalidate(); motionTimer = nil
        motion.stopDeviceMotionUpdates()
        tracker = WatchTransferOrientationTracker(orientation: orientation)
    }
}

struct LANTransferView: View {
    let reception: LANReceptionStatus
    let cancel: () -> Void
    @StateObject private var display = WatchTransferDisplay()
    @State private var showingDirection = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    #if DEBUG
    var previewOrientation: WatchTransferOrientation?
    #endif

    private var orientation: WatchTransferOrientation {
        #if DEBUG
        if let previewOrientation { return previewOrientation }
        #endif
        return display.orientation
    }

    private var progress: Double {
        min(1, max(0, Double(reception.completedBytes) / Double(max(1, reception.totalBytes))))
    }

    var body: some View {
        GeometryReader { geometry in
            // watchOS retains its clock in screen coordinates when our content
            // turns. Reserve that physical strip in every display direction.
            let top = max(26, geometry.safeAreaInsets.top)
            let available = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - top))
            let size = orientation.isLandscape
                ? CGSize(width: available.height, height: available.width) : available
            content(landscape: orientation.isLandscape)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(Double(orientation.rawValue)))
                .position(x: geometry.size.width / 2, y: top + available.height / 2)
                .animation(reducedLuminance ? nil : .easeInOut(duration: 0.2), value: orientation)
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear { display.start(foreground: scenePhase != .background) }
        .onDisappear { display.stop() }
        .onChange(of: scenePhase) { _, phase in display.setForeground(phase != .background) }
        .confirmationDialog("显示方向", isPresented: $showingDirection, titleVisibility: .visible) {
            Button("自动", action: display.useAutomaticOrientation)
            Button("旋转 90°", action: display.rotate)
            Button("取消", role: .cancel) {}
        }
    }

    private func content(landscape: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wifi").foregroundStyle(AppPalette.accent)
                Text("局域网").fontWeight(.medium)
                Spacer(minLength: 0)
                if display.isCharging {
                    Image(systemName: "bolt.fill").foregroundStyle(.green).accessibilityLabel("正在充电")
                }
                Text("\(reception.fileIndex)/\(reception.fileCount)").monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("第 \(reception.fileIndex) 首，共 \(reception.fileCount) 首")
            }.font(.system(size: 12))
            Spacer(minLength: 0)
            if landscape {
                HStack(spacing: 10) {
                    percentage
                    fileName(lines: 2).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                percentage
                fileName(lines: 1).frame(maxWidth: .infinity)
            }
            ProgressView(value: progress).tint(AppPalette.accent).accessibilityLabel("接收进度")
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button { showingDirection = true } label: {
                    Image(systemName: "rotate.right").frame(width: 44, height: 44)
                        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("显示方向")
                Button(action: cancel) {
                    Label("取消", systemImage: "xmark").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("取消局域网传输")
            }
        }
    }

    private var percentage: some View {
        Text(reception.isSaving ? "保存中" : "\(Int(progress * 100))%")
            .font(.system(size: reception.isSaving ? 24 : 34, weight: .semibold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(AppPalette.accent)
    }

    private func fileName(lines: Int) -> some View {
        Text((reception.fileName as NSString).deletingPathExtension)
            .font(.system(size: 13)).lineLimit(lines).truncationMode(.middle)
    }
}
