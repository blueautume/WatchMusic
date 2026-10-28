import SwiftUI

/// A movable player overlay. Its bounds alone accept touches, leaving the tab
/// bar, navigation and list layout unchanged.
struct FloatingPlayerView: View {
    @EnvironmentObject private var player: MusicPlayer
    let openPlayer: () -> Void
    @State private var isCollapsed = false
    @State private var anchor = CGPoint(x: 1, y: 1)
    @GestureState private var translation = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            if player.currentURL != nil {
                let panel = CGSize(width: isCollapsed ? 64 : min(380, geometry.size.width - 32),
                                   height: isCollapsed ? 64 : 88)
                let bounds = movementBounds(in: geometry, panel: panel)
                let resting = CGPoint(x: bounds.minX + bounds.width * anchor.x,
                                      y: bounds.minY + bounds.height * anchor.y)
                let position = clamped(CGPoint(x: resting.x + translation.width,
                                               y: resting.y + translation.height), to: bounds)
                Group {
                    if isCollapsed { collapsedPlayer }
                    else { expandedPlayer }
                }
                .frame(width: panel.width, height: panel.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isCollapsed ? 32 : 24))
                .overlay {
                    RoundedRectangle(cornerRadius: isCollapsed ? 32 : 24)
                        .stroke(AppPalette.textPrimary.opacity(0.10), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.16), radius: 16, y: 5)
                .position(position)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .updating($translation) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let final = clamped(CGPoint(x: resting.x + value.translation.width,
                                                        y: resting.y + value.translation.height), to: bounds)
                            anchor = CGPoint(x: bounds.width > 0 ? (final.x - bounds.minX) / bounds.width : anchor.x,
                                             y: bounds.height > 0 ? (final.y - bounds.minY) / bounds.height : anchor.y)
                        }
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("悬浮播放器")
            }
        }
    }

    private var expandedPlayer: some View {
        VStack(spacing: 0) {
            Capsule().fill(AppPalette.textSecondary.opacity(0.35)).frame(width: 28, height: 3)
                .padding(.top, 8).padding(.bottom, 5).accessibilityHidden(true)
            HStack(spacing: 6) {
                Button(action: openPlayer) {
                    HStack(spacing: 10) {
                        MusicArtwork(title: player.title, data: player.artworkData)
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppPalette.textPrimary).lineLimit(1)
                            if !player.artist.isEmpty {
                                Text(player.artist).font(.caption).foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("打开播放器：\(player.title)")
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Button(action: player.next) {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("下一首")
                Button { isCollapsed = true } label: {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).accessibilityLabel("收起悬浮播放器")
            }
            .foregroundStyle(AppPalette.accent).padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    private var collapsedPlayer: some View {
        Button { isCollapsed = false } label: {
            ZStack(alignment: .bottomTrailing) {
                MusicArtwork(title: player.title, data: player.artworkData)
                    .frame(width: 54, height: 54).clipShape(Circle())
                Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppPalette.controlForeground)
                    .frame(width: 22, height: 22).background(AppPalette.accent, in: Circle())
            }.frame(width: 64, height: 64)
        }
        .buttonStyle(.plain).accessibilityLabel("展开悬浮播放器：\(player.title)")
    }

    private func movementBounds(in geometry: GeometryProxy, panel: CGSize) -> CGRect {
        let left = 16 + panel.width / 2
        let top = 64 + panel.height / 2
        // Keep the navigation controls and tab bar outside the drag area.
        let right = max(left, geometry.size.width - 16 - panel.width / 2)
        let bottom = max(top, geometry.size.height - 76 - panel.height / 2)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func clamped(_ position: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX, max(bounds.minX, position.x)),
                y: min(bounds.maxY, max(bounds.minY, position.y)))
    }
}
