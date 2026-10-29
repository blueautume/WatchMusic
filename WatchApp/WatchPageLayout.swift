import SwiftUI

extension View {
    func watchPage(title: String, action: (() -> Void)? = nil, symbol: String = "xmark", showsBattery: Bool = false) -> some View {
        modifier(WatchPageLayout(title: title, action: action, symbol: symbol, showsBattery: showsBattery))
    }
}

/// The page keeps the navigation stack's local coordinates. Scrolling content
/// may draw outside its layout slot; only individual cards and artwork clip.
private struct WatchPageLayout: ViewModifier {
    @Environment(\.watchContentViewport) private var viewport
    let title: String
    let action: (() -> Void)?
    let symbol: String
    let showsBattery: Bool

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let metrics = viewport?.metrics ?? WatchSurfaceMetrics(physicalSize: geometry.size, orientation: .portrait)
            let insets = metrics.pageInsets(hasAction: action != nil, hasTitle: !title.isEmpty)
            VStack(spacing: 0) {
                Color.clear.frame(height: insets.headerHeight).allowsHitTesting(false).accessibilityHidden(true)
                content
                    .environment(\.watchPageInsets, insets)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollClipDisabled()
                    .contentMargins(.top, insets.scrollTop, for: .scrollContent)
                    .contentMargins(.bottom, insets.scrollBottom, for: .scrollContent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topLeading) { header(metrics: metrics, insets: insets) }
        }
        .ignoresSafeArea()
        .background(AppPalette.background)
        .navigationTitle("")
        .navigationBarBackButtonHidden()
        // Every destination uses the same hidden system bar, avoiding an inset
        // change while the native navigation transition is in flight.
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private func header(metrics: WatchSurfaceMetrics, insets: WatchPageInsets) -> some View {
        if title.isEmpty {
            if let action {
                navigationButton(action: action)
                    .offset(x: insets.backFrame.minX, y: insets.backFrame.minY)
            }
        } else {
            let portrait = metrics.orientation == .portrait
            let right = metrics.orientation == .landscapeRight
            let leading: CGFloat = right ? metrics.clockFrame.maxX + 6 : (action != nil ? 64 : 12)
            let trailing: CGFloat = right && action != nil ? 64 : 12
            let labelY: CGFloat = portrait ? metrics.clockFrame.maxY : (action != nil ? 12 : 5)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                    if showsBattery { WatchTitleBattery() }
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(AppPalette.background.opacity(0.92), in: Capsule())
                .frame(maxWidth: max(0, metrics.logicalSize.width - leading - trailing), alignment: .leading)
                .offset(x: leading, y: labelY)
                if let action {
                    navigationButton(action: action)
                        .offset(x: insets.backFrame.minX, y: insets.backFrame.minY)
                }
            }
            .frame(width: metrics.logicalSize.width, height: insets.headerHeight, alignment: .topLeading)
        }
    }

    private func navigationButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(AppPalette.surface, in: Circle())
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(AppPalette.textPrimary)
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
