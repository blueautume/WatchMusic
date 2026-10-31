import AVKit
import SwiftUI

struct PhoneNowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: PhoneLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingQueue = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    PhonePlayerPageLayout(viewport: geometry.size) {
                        HStack {
                            Text(player.currentURL?.deletingLastPathComponent().lastPathComponent ?? L10n.text("本地音乐"))
                                .font(.caption).foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                            Spacer()
                            PlaybackMoreMenu(library: library,
                                track: library.allTracks.first { $0.url == player.currentURL },
                                info: PlaybackInfo(player: player)).equatable()
                        }
                        MusicArtwork(title: player.title, data: player.artworkData)
                            .clipShape(RoundedRectangle(cornerRadius: 32))
                            .shadow(color: AppPalette.accent.opacity(0.1), radius: 30, y: 16)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(player.title.isEmpty ? L10n.text("未选择歌曲") : player.title)
                                .font(.system(.title, design: .rounded).weight(.bold))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !player.artist.isEmpty {
                                Text(player.artist).font(.subheadline).foregroundStyle(AppPalette.textSecondary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        PlaybackProgress(player: player)
                        transportControls
                        secondaryControls
                        if let deadline = player.sleepTimerDeadline {
                            SleepTimerCountdown(deadline: deadline)
                        }
                    }
                }
                #if DEBUG && targetEnvironment(simulator)
                .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-preview-player-bottom") ? .bottom : .top)
                #endif
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(AppPalette.background)
            .foregroundStyle(AppPalette.textPrimary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 44) }.accessibilityLabel(L10n.text("收起播放器")) }
                ToolbarItem(placement: .principal) { Text(L10n.text("正在播放")).font(.footnote.weight(.semibold)).foregroundStyle(AppPalette.textSecondary) }
                ToolbarItem(placement: .topBarTrailing) { Button { showingQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel(L10n.text("播放队列")) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingQueue) { QueueSheet().presentationDragIndicator(.visible) }
        }
        .alert(L10n.text("播放提示"), isPresented: Binding(get: { library.errorMessage != nil || player.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } })) {
            Button(L10n.text("好"), role: .cancel) { library.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(L10n.message(library.errorMessage ?? player.errorMessage ?? "")) }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-preview-queue") { showingQueue = true }
        }
        #endif
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: player.previous) { Image(systemName: "backward.end.fill").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel(L10n.text("上一首"))
            Button(action: player.togglePlayback) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .semibold)).offset(x: player.isPlaying ? 0 : 2).foregroundStyle(AppPalette.controlForeground).frame(width: 80, height: 80).background(AppPalette.accent, in: Circle()) }.accessibilityLabel(player.isPlaying ? L10n.text("暂停") : L10n.text("播放"))
            Button(action: player.next) { Image(systemName: "forward.end.fill").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel(L10n.text("下一首"))
        }.buttonStyle(.plain).disabled(player.currentURL == nil)
    }

    private var secondaryControls: some View {
        HStack(spacing: 0) {
            Button(action: player.cycleMode) {
                Image(systemName: player.mode.symbol).font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(L10n.text("播放模式，轻点切换")).accessibilityValue(player.mode.title)
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button { player.setRate(rate) } label: {
                        HStack {
                            Text(rate == 1 ? L10n.text("正常速度") : L10n.format("%@ 倍速", rate.formatted()))
                            if player.playbackRate == rate { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Image(systemName: "speedometer").font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(player.playbackRate == 1 ? AppPalette.textSecondary : AppPalette.accent)
            .accessibilityLabel(L10n.text("播放速度")).accessibilityValue(L10n.format("%@ 倍", player.playbackRate.formatted()))
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button(L10n.format("%lld 分钟后暂停", minutes)) { player.setSleepTimer(minutes: minutes) }
                }
                if player.sleepTimerDeadline != nil {
                    Button(L10n.text("关闭定时"), role: .destructive) { player.setSleepTimer(minutes: nil) }
                }
            } label: {
                Image(systemName: player.sleepTimerDeadline == nil ? "moon" : "moon.zzz.fill")
                    .font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(player.sleepTimerDeadline == nil ? AppPalette.textSecondary : AppPalette.accent)
            .accessibilityLabel(L10n.text("睡眠定时"))
            .accessibilityValue(player.sleepTimerDeadline == nil ? L10n.text("未开启") : L10n.text("已开启"))
            AudioRoutePicker()
                .frame(width: 44, height: 44).frame(maxWidth: .infinity)
                .accessibilityLabel(L10n.text("选择音频输出设备"))
        }
        .buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).padding(.top, 2)
    }

}

/// Measure text and controls at their natural height before sizing the artwork.
/// The ScrollView can still grow beyond the viewport for large text or short screens.
private struct PhonePlayerPageLayout: Layout {
    let viewport: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrangement(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, frame) in placement.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> PhonePlaybackLayout.Arrangement {
        let metrics = PhonePlaybackLayout(viewport: CGSize(width: proposal.width ?? viewport.width,
                                                          height: viewport.height))
        let heights = subviews.enumerated().map { index, view in
            index == 1 ? CGFloat.zero : view.sizeThatFits(ProposedViewSize(width: metrics.contentWidth, height: nil)).height
        }
        return metrics.arrange(sectionHeights: heights)
    }
}

/// The audio clock redraws only this subtree; menus never subscribe to a ticking publisher.
private struct PlaybackProgress: View {
    @ObservedObject var player: MusicPlayer
    @Environment(\.scenePhase) private var scenePhase
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5,
                                paused: scenePhase != .active || !player.isPlaying || isScrubbing)) { _ in
            let position = isScrubbing ? scrubValue : player.elapsed
            VStack(spacing: 7) {
                Slider(value: Binding(get: { position }, set: { value in
                    scrubValue = value
                    if !isScrubbing { player.seek(to: value) }
                }), in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
                    if editing { scrubValue = player.elapsed; isScrubbing = true }
                    else { player.seek(to: scrubValue); isScrubbing = false }
                })
                .tint(AppPalette.accent)
                .disabled(player.duration <= 0)
                .accessibilityAdjustableAction { direction in
                    if direction == .increment { player.skip(seconds: 5) }
                    else if direction == .decrement { player.skip(seconds: -5) }
                }
                .accessibilityLabel(L10n.text("播放进度"))
                .accessibilityValue(L10n.format("%@，共 %@", phoneTime(position), phoneTime(player.duration)))
                HStack {
                    Text(phoneTime(position))
                    Spacer()
                    Text("−" + phoneTime(max(0, player.duration - position)))
                }.font(.caption.monospacedDigit()).foregroundStyle(AppPalette.textSecondary)
            }
        }
        .onChange(of: player.currentURL) { _, _ in isScrubbing = false }
    }
}

private struct SleepTimerCountdown: View {
    let deadline: Date
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { context in
            Label(L10n.format("将在 %@ 后暂停", phoneTime(max(0, deadline.timeIntervalSince(context.date)))), systemImage: "moon.zzz.fill")
                .font(.footnote)
                .foregroundStyle(AppPalette.accent)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(AppPalette.accent.opacity(0.1), in: Capsule())
        }
    }
}

private struct PlaybackInfo: Equatable {
    let url: URL?
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let format: String
    let route: String

    @MainActor init(player: MusicPlayer) {
        url = player.currentURL
        title = player.title
        artist = player.artist
        album = player.album
        duration = player.duration
        format = player.formatName
        route = player.routeDescription
    }
}

/// A stable snapshot keeps an open native menu independent of unrelated transfer updates.
private struct PlaybackMoreMenu: View, Equatable {
    let library: PhoneLibrary
    let track: PhoneTrack?
    let info: PlaybackInfo
    @State private var showingInfo = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.library === rhs.library && lhs.info == rhs.info
            && lhs.track?.id == rhs.track?.id && lhs.track?.url == rhs.track?.url
    }

    var body: some View {
        Menu {
            if let track {
                Button(L10n.text("发送到 Apple Watch"), systemImage: "applewatch.and.arrow.forward") {
                    // Read current file metadata when the action runs, keeping
                    // an open menu independent of asynchronous duration scans.
                    if let current = library.allTracks.first(where: { $0.id == track.id && $0.url == track.url }) {
                        library.send([current], retryPending: true)
                    }
                }
            }
            Button(L10n.text("歌曲信息"), systemImage: "info.circle") { showingInfo = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(AppPalette.surface, in: Circle())
        }
        .accessibilityLabel(L10n.text("更多播放选项"))
        .alert(L10n.text("歌曲信息"), isPresented: $showingInfo) { Button(L10n.text("好"), role: .cancel) {} } message: {
            Text(L10n.format("%@\n艺术家：%@\n专辑：%@\n时长：%@\n格式：%@\n%@", info.title, info.artist.isEmpty ? L10n.text("未知") : info.artist, info.album.isEmpty ? L10n.text("未知") : info.album, phoneTime(info.duration), info.format, info.route))
        }
    }
}

private struct QueueSheet: View {
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(player.queue.enumerated()), id: \.element) { index, url in
                        Button { player.play(url, in: player.queue) } label: {
                            HStack(spacing: 14) {
                                if player.currentURL == url { Image(systemName: "waveform").foregroundStyle(AppPalette.accent).frame(width: 22) }
                                else { Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(AppPalette.textSecondary).frame(width: 22) }
                                VStack(alignment: .leading, spacing: 5) { Text(url.deletingPathExtension().lastPathComponent).font(.subheadline).foregroundStyle(player.currentURL == url ? AppPalette.accent : AppPalette.textPrimary); Text(url.deletingLastPathComponent().lastPathComponent).font(.caption2).foregroundStyle(AppPalette.textSecondary) }
                            }.padding(.vertical, 4)
                        }.listRowBackground(AppPalette.surface)
                    }
                } header: { Text(L10n.format("%lld 首 · %@", player.queue.count, player.mode.title)) }
            }.scrollContentBackground(.hidden).background(AppPalette.background).navigationTitle(L10n.text("播放队列")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成")) { dismiss() } } }
        }
    }
}

private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(AppPalette.accent)
        view.activeTintColor = UIColor(AppPalette.accent)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(AppPalette.textSecondary)
        uiView.activeTintColor = UIColor(AppPalette.accent)
    }
}
