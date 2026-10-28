import SwiftUI

struct WatchContentViewport {
    let size: CGSize
    let orientation: WatchTransferOrientation
    let topInset: CGFloat

    func center(in geometry: GeometryProxy) -> CGPoint {
        WatchSurfaceMetrics.localContentCenter(size: geometry.size, topInset: topInset)
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

/// The navigation stack owns its page layout and transition coordinates. Only
/// this outer canvas rotates; watchOS keeps ownership of the system clock.
struct WatchAppSurface<Content: View>: View {
    @EnvironmentObject private var display: WatchAppDisplay
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geometry in
            let metrics = WatchSurfaceMetrics(physicalSize: geometry.size, orientation: display.orientation)
            let viewport = WatchContentViewport(size: metrics.contentSize,
                orientation: display.orientation, topInset: metrics.fullCanvasTopInset)
            content
                .environment(\.watchContentViewport, viewport)
                .frame(width: metrics.logicalSize.width, height: metrics.logicalSize.height)
                .background(AppPalette.background)
                .clipped()
                .rotationEffect(.degrees(Double(display.orientation.rawValue)))
                .position(metrics.physicalCanvasCenter(in: CGRect(origin: .zero, size: geometry.size)))
                .animation(reducedLuminance ? nil : .easeInOut(duration: 0.2), value: display.orientation)
        }
        .ignoresSafeArea()
        .foregroundStyle(AppPalette.textPrimary)
        .background(AppPalette.background)
        .persistentSystemOverlays(.visible)
    }

}
