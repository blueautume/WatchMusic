import SwiftUI

/// A counterpart remote: no track metadata or position leaves its player.
struct RemotePlaybackControlsView: View {
    @ObservedObject private var remote = PlaybackControlCenter.shared

    #if os(watchOS)
    private let deviceName = "iPhone"
    private let deviceIcon = "iphone"
    #else
    private let deviceName = "手表"
    private let deviceIcon = "applewatch"
    #endif

    private var status: String {
        if !remote.isReachable { return "未连接" }
        if !remote.isPeerConfirmed { return "连接中" }
        if remote.peerState?.isPreparing == true { return "准备中" }
        return remote.peerState?.isPlaying == true ? "播放中" : "已暂停"
    }
    private var wantsPause: Bool { remote.peerState?.isPlaying == true || remote.peerState?.isPreparing == true }

    var body: some View {
        if remote.hasRemoteItem {
            #if os(watchOS)
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Label(deviceName, systemImage: deviceIcon)
                    Spacer(minLength: 0)
                    Text(status).foregroundStyle(.secondary)
                }.font(.caption2)
                controls
                if let error = remote.lastError { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            #else
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(deviceName, systemImage: deviceIcon).font(.subheadline.weight(.medium))
                        Text(status).font(.caption2).foregroundStyle(AppPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    controls
                }
                if let error = remote.lastError { Text(error).font(.caption2).foregroundStyle(AppPalette.textSecondary) }
            }
            .padding(12).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16).padding(.bottom, 8)
            #endif
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { remote.send(.previous) } label: {
                Image(systemName: "backward.end.fill").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("\(deviceName)上一首")
                .disabled(!remote.canControl || remote.peerState?.isPreparing == true)
            Button { remote.send(wantsPause ? .pause : .play) } label: {
                Image(systemName: wantsPause ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("\(deviceName)\(wantsPause ? "暂停" : "播放")")
                .disabled(!remote.canControl)
            Button { remote.send(.next) } label: {
                Image(systemName: "forward.end.fill").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("\(deviceName)下一首")
                .disabled(!remote.canControl || remote.peerState?.isPreparing == true)
        }.font(.system(size: 19, weight: .semibold)).buttonStyle(.plain).foregroundStyle(AppPalette.accent)
    }
}
