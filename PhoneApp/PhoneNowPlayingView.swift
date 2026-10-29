import AVKit
import SwiftUI

struct PhoneNowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: PhoneLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var showingQueue = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    let artworkSide = min(geometry.size.width - 56, max(160, min(geometry.size.height * 0.32, 330)))
                    VStack(spacing: 22) {
                        HStack {
                            Text(player.currentURL?.deletingLastPathComponent().lastPathComponent ?? "本地音乐")
                                .font(.caption).foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                            Spacer()
                            PlaybackMoreMenu(library: library,
                                track: library.allTracks.first { $0.url == player.currentURL },
                                info: PlaybackInfo(player: player)).equatable()
                        }
                        MusicArtwork(title: player.title, data: player.artworkData)
                            .frame(width: artworkSide, height: artworkSide)
                            .clipShape(RoundedRectangle(cornerRadius: 32))
                            .shadow(color: AppPalette.accent.opacity(0.1), radius: 30, y: 16)
                            .padding(.vertical, 8)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(player.title.isEmpty ? "未选择歌曲" : player.title).font(.system(size: 28, weight: .bold, design: .rounded)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            if !player.artist.isEmpty { Text(player.artist).font(.subheadline).foregroundStyle(AppPalette.textSecondary).lineLimit(2) }
                        }
                        PlaybackProgress(player: player)
                        transportControls
                        secondaryControls
                        if let deadline = player.sleepTimerDeadline {
                            SleepTimerCountdown(deadline: deadline)
                        }
                    }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 28)
                }
            }
            .background(AppPalette.background)
            .foregroundStyle(AppPalette.textPrimary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 44) }.accessibilityLabel("收起播放器") }
                ToolbarItem(placement: .principal) { Text("正在播放").font(.footnote.weight(.semibold)).foregroundStyle(AppPalette.textSecondary) }
                ToolbarItem(placement: .topBarTrailing) { Button { showingQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放队列") }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingQueue) { QueueSheet().presentationDragIndicator(.visible) }
        }
        .alert("播放提示", isPresented: Binding(get: { library.errorMessage != nil || player.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(library.errorMessage ?? player.errorMessage ?? "") }
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: player.previous) { Image(systemName: "backward.end.fill").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel("上一首")
            Button(action: player.togglePlayback) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .semibold)).offset(x: player.isPlaying ? 0 : 2).foregroundStyle(AppPalette.controlForeground).frame(width: 80, height: 80).background(AppPalette.accent, in: Circle()) }.accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            Button(action: player.next) { Image(systemName: "forward.end.fill").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel("下一首")
        }.buttonStyle(.plain).disabled(player.currentURL == nil)
    }

    private var secondaryControls: some View {
        HStack(spacing: 0) {
            Button(action: player.cycleMode) {
                Image(systemName: player.mode.symbol).font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("播放模式，轻点切换").accessibilityValue(player.mode.title)
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button { player.setRate(rate) } label: {
                        HStack {
                            Text(rate == 1 ? "正常速度" : "\(rate.formatted()) 倍速")
                            if player.playbackRate == rate { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Image(systemName: "speedometer").font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(player.playbackRate == 1 ? AppPalette.textSecondary : AppPalette.accent)
            .accessibilityLabel("播放速度").accessibilityValue("\(player.playbackRate.formatted()) 倍")
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) 分钟后暂停") { player.setSleepTimer(minutes: minutes) }
                }
                if player.sleepTimerDeadline != nil {
                    Button("关闭定时", role: .destructive) { player.setSleepTimer(minutes: nil) }
                }
            } label: {
                Image(systemName: player.sleepTimerDeadline == nil ? "moon" : "moon.zzz.fill")
                    .font(.system(size: 20)).frame(width: 44, height: 44)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(player.sleepTimerDeadline == nil ? AppPalette.textSecondary : AppPalette.accent)
            .accessibilityLabel("睡眠定时")
            .accessibilityValue(player.sleepTimerDeadline == nil ? "未开启" : "已开启")
            AudioRoutePicker()
                .frame(width: 44, height: 44).frame(maxWidth: .infinity)
                .accessibilityLabel("选择音频输出设备")
        }
        .buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).padding(.top, 2)
    }

}

/// The audio clock redraws only this subtree; menus never subscribe to a ticking publisher.
private struct PlaybackProgress: View {
    @ObservedObject var player: MusicPlayer
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !player.isPlaying || isScrubbing)) { _ in
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
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(phoneTime(position))，共 \(phoneTime(player.duration))")
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label("将在 \(phoneTime(max(0, deadline.timeIntervalSince(context.date)))) 后暂停", systemImage: "moon.zzz.fill")
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
                Button("发送到 Apple Watch", systemImage: "applewatch.and.arrow.forward") {
                    // Read current file metadata when the action runs, keeping
                    // an open menu independent of asynchronous duration scans.
                    if let current = library.allTracks.first(where: { $0.id == track.id && $0.url == track.url }) {
                        library.send([current], retryPending: true)
                    }
                }
            }
            Button("歌曲信息", systemImage: "info.circle") { showingInfo = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(AppPalette.surface, in: Circle())
        }
        .accessibilityLabel("更多播放选项")
        .alert("歌曲信息", isPresented: $showingInfo) { Button("好", role: .cancel) {} } message: {
            Text("\(info.title)\n艺术家：\(info.artist.isEmpty ? "未知" : info.artist)\n专辑：\(info.album.isEmpty ? "未知" : info.album)\n时长：\(phoneTime(info.duration))\n格式：\(info.format)\n\(info.route)")
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
                } header: { Text("\(player.queue.count) 首 · \(player.mode.title)") }
            }.scrollContentBackground(.hidden).background(AppPalette.background).navigationTitle("播放队列").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
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
