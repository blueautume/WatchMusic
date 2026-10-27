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

private struct WatchStatusRowHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var watchStatusRowHeight: CGFloat? {
        get { self[WatchStatusRowHeightKey.self] }
        set { self[WatchStatusRowHeightKey.self] = newValue }
    }
    var watchContentViewport: WatchContentViewport? {
        get { self[WatchContentViewportKey.self] }
        set { self[WatchContentViewportKey.self] = newValue }
    }
}

/// App content turns below the physical system clock; battery stays alongside
/// that clock. Each presented sheet owns a surface, navigation destinations do not.
struct WatchAppSurface<Content: View>: View {
    @EnvironmentObject private var display: WatchAppDisplay
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @Environment(\.watchStatusRowHeight) private var inheritedStatusRowHeight
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { safeGeometry in
            surface(topInset: safeGeometry.safeAreaInsets.top)
        }
        .background(AppPalette.background)
        .persistentSystemOverlays(.visible)
    }

    private func surface(topInset: CGFloat) -> some View {
        GeometryReader { geometry in
            // Sheet navigation adds its own insets. Reuse the physical status
            // row from the window so battery never moves between app pages.
            let header = inheritedStatusRowHeight ?? (topInset < 50 ? 30 : topInset)
            let available = CGSize(width: geometry.size.width, height: max(0, geometry.size.height - header))
            let size = display.orientation.isLandscape
                ? CGSize(width: available.height, height: available.width) : available
            let bounds = geometry.frame(in: .global)
            let viewport = WatchContentViewport(size: size,
                physicalCenter: CGPoint(x: bounds.midX, y: bounds.minY + header + available.height / 2),
                orientation: display.orientation)
            ZStack(alignment: .topLeading) {
                content
                    .environment(\.watchContentViewport, viewport)
                    .environment(\.watchStatusRowHeight, header)
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(Double(display.orientation.rawValue)))
                    .position(x: geometry.size.width / 2, y: header + available.height / 2)
                    .animation(reducedLuminance ? nil : .easeInOut(duration: 0.2), value: display.orientation)
                    .zIndex(0)
                battery
                    .frame(height: header)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    private var battery: some View {
        HStack(spacing: 3) {
            if display.isCharging { Image(systemName: "bolt.fill").font(.system(size: 10, weight: .semibold)) }
            Text(display.batteryPercentage.map { "\($0)%" } ?? "—%")
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(display.isCharging ? Color.green : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.batteryPercentage.map { "电量百分之\($0)" } ?? "电量暂不可用")
        .accessibilityValue(display.isCharging ? "正在充电" : "未充电")
    }
}
