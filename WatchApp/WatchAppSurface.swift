import SwiftUI

struct WatchContentViewport {
    let size: CGSize
    let orientation: WatchTransferOrientation
    let clockFrame: CGRect
    let metrics: WatchSurfaceMetrics
}

private struct WatchContentViewportKey: EnvironmentKey {
    static let defaultValue: WatchContentViewport? = nil
}

private struct WatchPageInsetsKey: EnvironmentKey {
    static let defaultValue: WatchPageInsets? = nil
}

extension EnvironmentValues {
    var watchContentViewport: WatchContentViewport? {
        get { self[WatchContentViewportKey.self] }
        set { self[WatchContentViewportKey.self] = newValue }
    }
    var watchPageInsets: WatchPageInsets? {
        get { self[WatchPageInsetsKey.self] }
        set { self[WatchPageInsetsKey.self] = newValue }
    }
}

/// Navigation owns each page's local coordinates. Only the outer full-size
/// canvas rotates, without a rectangular clock strip or ancestor scroll mask.
struct WatchAppSurface<Content: View>: View {
    @EnvironmentObject private var display: WatchAppDisplay
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geometry in
            let metrics = WatchSurfaceMetrics(physicalSize: geometry.size, orientation: display.orientation)
            content
                .environment(\.watchContentViewport, WatchContentViewport(size: metrics.logicalSize,
                    orientation: display.orientation, clockFrame: metrics.clockFrame, metrics: metrics))
                .frame(width: metrics.logicalSize.width, height: metrics.logicalSize.height)
                .background(AppPalette.background)
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
