import SwiftUI

extension View {
    func watchPage(title: String, action: (() -> Void)? = nil, symbol: String = "xmark") -> some View {
        modifier(WatchPageLayout(title: title, action: action, symbol: symbol))
    }
}

/// Keeps app navigation below the physical clock/battery strip. Native watch
/// navigation bars reserve window insets even when their content is rotated.
private struct WatchPageLayout: ViewModifier {
    @Environment(\.watchContentViewport) private var viewport
    let title: String
    let action: (() -> Void)?
    let symbol: String

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let size = viewport?.size ?? geometry.size
            let compact = size.width < 180 || size.height < 185
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    if symbol == "chevron.left", let action { navigationButton(action: action) }
                    Text(title)
                        .font(.system(size: compact ? 14 : 16, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if symbol != "chevron.left", let action { navigationButton(action: action) }
                }
                .padding(.horizontal, 12)
                .frame(height: action == nil ? 28 : 44)
                .background(AppPalette.background)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: size.width, height: size.height)
            .position(viewport?.center(in: geometry) ?? CGPoint(x: size.width / 2, y: size.height / 2))
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
    }

    private func navigationButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(symbol == "chevron.left" ? "返回" : "关闭")
    }
}
