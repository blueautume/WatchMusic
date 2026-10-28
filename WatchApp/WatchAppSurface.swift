import SwiftUI

struct WatchContentViewport {
    let size: CGSize
    let physicalCenter: CGPoint
    let orientation: WatchTransferOrientation

    func center(in geometry: GeometryProxy) -> CGPoint {
        let bounds = geometry.frame(in: .global)
        let dx = physicalCenter.x - bounds.midX
        let dy = physicalCenter.y - bounds.midY
        let angle = Double(orientation.rawValue) * .pi / 180
        return CGPoint(x: geometry.size.width / 2 + dx * cos(angle) + dy * sin(angle),
                       y: geometry.size.height / 2 - dx * sin(angle) + dy * cos(angle))
    }
}

private struct WatchContentViewportKey: EnvironmentKey {
    static let defaultValue: WatchContentViewport? = nil
}

extension EnvironmentValues {
    var watchContentViewport: WatchContentViewport? {
        get { self[WatchContentViewportKey.self] }
        set { self[WatchContentViewportKey.self] = newValue }
    }
}

/// Pages and battery share one logical canvas. A separate physical inset keeps
/// watchOS's fixed system clock clear. Sheets own their own surface.
struct WatchAppSurface<Content: View>: View {
    @EnvironmentObject private var display: WatchAppDisplay
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geometry in
            let metrics = WatchSurfaceMetrics(physicalSize: geometry.size, orientation: display.orientation)
            let viewport = WatchContentViewport(size: metrics.contentSize,
                physicalCenter: metrics.physicalContentCenter(in: geometry.frame(in: .global)),
                orientation: display.orientation)
            ZStack(alignment: .topLeading) {
                content
                    .environment(\.watchContentViewport, viewport)
                    .frame(width: metrics.contentSize.width, height: metrics.contentSize.height)
                    .position(x: metrics.logicalSize.width / 2,
                              y: metrics.statusHeight + metrics.contentSize.height / 2)
                statusRow
                    .padding(.horizontal, metrics.statusInset)
                    .padding(.top, display.orientation == .portrait ? 3 : 0)
                    .frame(width: metrics.logicalSize.width, height: metrics.statusHeight)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
            .frame(width: metrics.logicalSize.width, height: metrics.logicalSize.height)
            .rotationEffect(.degrees(Double(display.orientation.rawValue)))
            .position(metrics.physicalCanvasCenter(in: CGRect(origin: .zero, size: geometry.size)))
            .animation(reducedLuminance ? nil : .easeInOut(duration: 0.2), value: display.orientation)
        }
        .ignoresSafeArea()
        .foregroundStyle(AppPalette.textPrimary)
        .background(AppPalette.background)
        .persistentSystemOverlays(.visible)
    }

    private var statusRow: some View {
        HStack {
            battery
            Spacer(minLength: 8)
        }
    }

    private var battery: some View {
        HStack(spacing: 3) {
            if display.isCharging { Image(systemName: "bolt.fill").font(.system(size: 10, weight: .semibold)) }
            Text(display.batteryPercentage.map { "\($0)%" } ?? "—%")
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(display.isCharging ? Color.green : AppPalette.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.batteryPercentage.map { "电量百分之\($0)" } ?? "电量暂不可用")
        .accessibilityValue(display.isCharging ? "正在充电" : "未充电")
    }
}
