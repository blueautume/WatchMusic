import SwiftUI

extension View {
    func watchPage(title: String, action: (() -> Void)? = nil, symbol: String = "xmark", showsBattery: Bool = false) -> some View {
        modifier(WatchPageLayout(title: title, action: action, symbol: symbol, showsBattery: showsBattery))
    }
}

/// Pages stay in the navigation stack's local coordinate space. In particular,
/// an animated push must not be cancelled by pinning a page to a global center.
private struct WatchPageLayout: ViewModifier {
    let title: String
    let action: (() -> Void)?
    let symbol: String
    let showsBattery: Bool

    private var usesNativeBack: Bool { action != nil && symbol == "chevron.left" }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let compact = size.width < 180 || size.height < 185
            VStack(spacing: 0) {
                if !usesNativeBack {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: compact ? 14 : 16, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .layoutPriority(1)
                        if showsBattery { WatchTitleBattery() }
                        Spacer(minLength: 0)
                        if let action { navigationButton(action: action) }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: action == nil ? 28 : 44)
                    .background(AppPalette.background)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: size.width, height: size.height)
            .background(AppPalette.background)
            .clipped()
        }
        .background(AppPalette.background)
        .navigationTitle(usesNativeBack ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        // Reserve the same native bar area on both sides of a push. Changing
        // bar visibility mid-transition changes the destination's safe area.
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(AppPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(!usesNativeBack)
    }

    private func navigationButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(AppPalette.surface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(symbol == "chevron.left" ? "返回" : "关闭")
    }
}

/// Battery state belongs beside the page title, not in a second system-status
/// row. Its observer is isolated from the navigation stack and menu contents.
struct WatchTitleBattery: View {
    @EnvironmentObject private var display: WatchAppDisplay

    var body: some View {
        HStack(spacing: 3) {
            if display.isCharging { Image(systemName: "bolt.fill").font(.system(size: 9, weight: .semibold)) }
            Text(display.batteryPercentage.map { "\($0)%" } ?? "—%")
                .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .fixedSize()
        .padding(.horizontal, 5).padding(.vertical, 3)
        .foregroundStyle(display.isCharging ? Color.green : AppPalette.textSecondary)
        .background(AppPalette.surface, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.batteryPercentage.map { "电量百分之\($0)" } ?? "电量暂不可用")
        .accessibilityValue(display.isCharging ? "正在充电" : "未充电")
    }
}
