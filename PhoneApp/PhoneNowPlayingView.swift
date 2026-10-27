import AVKit
import SwiftUI

struct PhoneNowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: PhoneLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showingQueue = false
    @State private var showingInfo = false

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
                            Menu {
                                if let track = library.allTracks.first(where: { $0.url == player.currentURL }) { Button("发送到 Apple Watch", systemImage: "applewatch.and.arrow.forward") { library.send([track], retryPending: true) } }
                                Button("歌曲信息", systemImage: "info.circle") { showingInfo = true }
                            } label: { Image(systemName: "ellipsis").font(.title3).foregroundStyle(.white).frame(width: 44, height: 44).background(AppPalette.surface, in: Circle()) }.accessibilityLabel("更多播放选项")
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
                        progressControl
                        transportControls
                        secondaryControls
                        volumeControl
                        outputControl
                        if let remaining = player.sleepRemaining {
                            Label("将在 \(phoneTime(remaining)) 后暂停", systemImage: "moon.zzz.fill").font(.footnote).foregroundStyle(AppPalette.accent).padding(.vertical, 12).frame(maxWidth: .infinity).background(AppPalette.accent.opacity(0.1), in: Capsule())
                        }
                    }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 28)
                }
            }
            .background(AppPalette.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 44) }.accessibilityLabel("收起播放器") }
                ToolbarItem(placement: .principal) { Text("正在播放").font(.footnote.weight(.semibold)).foregroundStyle(AppPalette.textSecondary) }
                ToolbarItem(placement: .topBarTrailing) { Button { showingQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放队列") }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingQueue) { QueueSheet().presentationDragIndicator(.visible) }
            .alert("歌曲信息", isPresented: $showingInfo) { Button("好", role: .cancel) {} } message: { Text("\(player.title)\n艺术家：\(player.artist.isEmpty ? "未知" : player.artist)\n专辑：\(player.album.isEmpty ? "未知" : player.album)\n时长：\(phoneTime(player.duration))\n格式：\(player.formatName)\n\(player.routeDescription)") }
        }
        .preferredColorScheme(.dark)
        .alert("播放提示", isPresented: Binding(get: { library.errorMessage != nil || player.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(library.errorMessage ?? player.errorMessage ?? "") }
    }

    private var progressControl: some View {
        VStack(spacing: 7) {
            Slider(value: Binding(get: { isScrubbing ? scrubValue : player.elapsed }, set: { value in
                scrubValue = value
                if !isScrubbing { player.seek(to: value) }
            }), in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
                if editing { scrubValue = player.elapsed; isScrubbing = true }
                else { player.seek(to: scrubValue); isScrubbing = false }
            }).tint(AppPalette.accent).disabled(player.duration <= 0)
                .accessibilityAdjustableAction { direction in
                    if direction == .increment { player.skip(seconds: 5) }
                    else if direction == .decrement { player.skip(seconds: -5) }
                }.accessibilityLabel("播放进度").accessibilityValue("\(phoneTime(isScrubbing ? scrubValue : player.elapsed))，共 \(phoneTime(player.duration))")
            HStack { Text(phoneTime(isScrubbing ? scrubValue : player.elapsed)); Spacer(); Text("−" + phoneTime(max(0, player.duration - (isScrubbing ? scrubValue : player.elapsed)))) }.font(.caption.monospacedDigit()).foregroundStyle(AppPalette.textSecondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: player.previous) { Image(systemName: "backward.end.fill").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel("上一首")
            Button(action: player.togglePlayback) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .semibold)).offset(x: player.isPlaying ? 0 : 2).foregroundStyle(.black).frame(width: 80, height: 80).background(AppPalette.accent, in: Circle()) }.accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            Button(action: player.next) { Image(systemName: "forward.end.fill").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel("下一首")
        }.buttonStyle(.plain).disabled(player.currentURL == nil)
    }

    private var secondaryControls: some View {
        HStack {
            Button(action: player.cycleMode) {
                VStack(spacing: 7) { Image(systemName: player.mode.symbol).font(.system(size: 20)); Text(player.mode.title).font(.caption2) }.frame(maxWidth: .infinity, minHeight: 50)
            }.accessibilityLabel("播放模式：\(player.mode.title)，轻点切换")
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button { player.setRate(rate) } label: { HStack { Text(rate == 1 ? "正常速度" : "\(rate.formatted()) 倍速"); if player.playbackRate == rate { Image(systemName: "checkmark") } } }
                }
            } label: { VStack(spacing: 7) { Text("\(player.playbackRate.formatted())×").font(.system(size: 18, weight: .semibold, design: .rounded)); Text("播放速度").font(.caption2) }.frame(maxWidth: .infinity, minHeight: 50) }.accessibilityLabel("播放速度，\(player.playbackRate.formatted()) 倍")
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) 分钟后暂停") { player.setSleepTimer(minutes: minutes) } }
                if player.sleepRemaining != nil { Button("关闭定时", role: .destructive) { player.setSleepTimer(minutes: nil) } }
            } label: { VStack(spacing: 7) { Image(systemName: player.sleepRemaining == nil ? "moon" : "moon.zzz.fill").font(.system(size: 20)); Text("睡眠定时").font(.caption2) }.frame(maxWidth: .infinity, minHeight: 50) }.accessibilityLabel("睡眠定时")
        }.buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).padding(.top, 2)
    }

    private var volumeControl: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill").font(.caption)
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1).tint(.white).accessibilityLabel("应用播放音量")
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }.foregroundStyle(AppPalette.textSecondary)
    }

    private var outputControl: some View {
        HStack(spacing: 12) {
            AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel("选择音频输出设备")
            VStack(alignment: .leading, spacing: 4) {
                Text("音频输出").font(.caption2).foregroundStyle(AppPalette.textSecondary)
                Text(player.routeDescription).font(.caption).lineLimit(2)
            }
            Spacer()
            Text(player.formatName).font(.caption2.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
        }.padding(14).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
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
                                VStack(alignment: .leading, spacing: 5) { Text(url.deletingPathExtension().lastPathComponent).font(.subheadline).foregroundStyle(player.currentURL == url ? AppPalette.accent : .white); Text(url.deletingLastPathComponent().lastPathComponent).font(.caption2).foregroundStyle(AppPalette.textSecondary) }
                            }.padding(.vertical, 4)
                        }.listRowBackground(AppPalette.surface)
                    }
                } header: { Text("\(player.queue.count) 首 · \(player.mode.title)") }
            }.scrollContentBackground(.hidden).background(AppPalette.background).navigationTitle("播放队列").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark)
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
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
