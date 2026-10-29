import SwiftUI
import WatchKit

/// Playback and navigation share the full local canvas; the page header owns
/// Back and the system-clock clearance without a second native toolbar inset.
struct NowPlayingView: View {
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeDialog: PlaybackDialog?
    @State private var choosingOutput = false
    @State private var isOnScreen = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var previewApplied = false
    #endif

    private var acceptsCrownInput: Bool {
        isOnScreen && scenePhase == .active && activeDialog == nil && !choosingOutput && player.currentURL != nil
    }

    var body: some View {
        WatchPlaybackPageContent(
            choosingOutput: choosingOutput,
            acceptsPrimaryGesture: acceptsCrownInput && !player.isPreparing,
            chooseSpeed: { activeDialog = .speed },
            chooseSleep: { activeDialog = .sleep },
            chooseOutput: {
                choosingOutput = true
                player.requestAudioOutput { choosingOutput = false }
            }
        )
        .background(AppPalette.background)
        .watchPage(title: "", action: { dismiss() }, symbol: "chevron.left")
        .overlay {
            WatchVolumeFeedbackOverlay(isActive: acceptsCrownInput)
        }
        // The accessory wasn't mounted by this non-scrolling page, so its
        // volume control never existed to request Crown focus.
        // Keep the native control mounted at normal size/opacity behind the
        // opaque page instead; hiding it would make native focus unreliable.
        .background(alignment: .trailing) {
            WatchCrownVolumeControl(isFocused: acceptsCrownInput, isPlaying: player.isPlaying)
                .frame(width: 28, height: 64)
                .accessibilityHidden(true)
        }
        .confirmationDialog(activeDialog?.title ?? "", isPresented: dialogPresented, titleVisibility: .visible) {
            dialogActions
        }
        .onAppear {
            WatchCrownDiagnostics.record("page-appeared")
            isOnScreen = true
            #if DEBUG && targetEnvironment(simulator)
            if !previewApplied {
                previewApplied = true
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-preview-playback-rate") { activeDialog = .speed }
                if arguments.contains("-preview-sleep-timer") { activeDialog = .sleep }
            }
            #endif
        }
        .onDisappear {
            WatchCrownDiagnostics.record("page-disappeared")
            isOnScreen = false
            activeDialog = nil
        }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-preview-crown-cycle") else { return }
            // One cancellable test sequence exercises real presentation and
            // NavigationStack teardown without synthesizing Crown/OS input.
            do {
                guard await WatchCrownDiagnostics.waitForInitialFocusRequest() else { return }
                try await Task.sleep(for: .milliseconds(400))
                guard isOnScreen else { return }
                WatchCrownDiagnostics.record("cycle-dialog-open")
                activeDialog = .speed
                try await Task.sleep(for: .milliseconds(600))
                guard isOnScreen else { return }
                WatchCrownDiagnostics.record("cycle-dialog-close")
                activeDialog = nil
                try await Task.sleep(for: .milliseconds(600))
                guard isOnScreen else { return }
                WatchCrownDiagnostics.record("cycle-page-dismiss")
                dismiss()
            } catch { return }
        }
        #endif
    }

    private var dialogPresented: Binding<Bool> {
        Binding(get: { activeDialog != nil }, set: { if !$0 { activeDialog = nil } })
    }

    @ViewBuilder private var dialogActions: some View {
        switch activeDialog {
        case .speed:
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                Button {
                    player.setRate(rate)
                    activeDialog = nil
                } label: {
                    if player.playbackRate == rate { Label(String(format: "%g×", rate), systemImage: "checkmark") }
                    else { Text(String(format: "%g×", rate)) }
                }
            }
        case .sleep:
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) 分钟") {
                    player.setSleepTimer(minutes: minutes)
                    activeDialog = nil
                }
            }
            if player.sleepTimerDeadline != nil {
                Button("关闭定时", role: .destructive) {
                    player.setSleepTimer(minutes: nil)
                    activeDialog = nil
                }
            }
        case nil:
            EmptyView()
        }
        Button("取消", role: .cancel) { activeDialog = nil }
    }
}

/// This child receives the local clock-clearance values injected by watchPage.
private struct WatchPlaybackPageContent: View {
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.watchPageInsets) private var pageInsets
    let choosingOutput: Bool
    let acceptsPrimaryGesture: Bool
    let chooseSpeed: @MainActor () -> Void
    let chooseSleep: @MainActor () -> Void
    let chooseOutput: @MainActor () -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = WatchPlaybackLayout(size: geometry.size,
                minimumBottom: pageInsets?.bottomControlBottom ?? 0)
            VStack(spacing: layout.spacing) {
                metadata(layout: layout)
                    .padding(.leading, max(0, (pageInsets?.metadataLeading ?? 0) - layout.horizontalInset))
                    .padding(.trailing, max(0, (pageInsets?.metadataTrailing ?? 0) - layout.horizontalInset))
                    .frame(height: layout.metadataHeight)
                playbackOptions(height: layout.optionsHeight)
                mainControls(height: layout.transportHeight)
                    .padding(.leading, max(0, (pageInsets?.bottomControlLeading ?? 0) - layout.horizontalInset))
                    .padding(.trailing, max(0, (pageInsets?.bottomControlTrailing ?? 0) - layout.horizontalInset))
            }
            .padding(.horizontal, layout.horizontalInset)
            .padding(.bottom, layout.bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(AppPalette.background)
    }

    private func metadata(layout: WatchPlaybackLayout) -> some View {
        HStack(spacing: layout.compact ? 8 : 10) {
            MusicArtwork(title: player.title, data: player.artworkData)
                .frame(width: layout.artworkSize, height: layout.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: layout.compact ? 9 : 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.isPreparing ? "正在准备…" : player.title)
                    .font(.system(size: layout.compact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                    .lineLimit(layout.tight ? 1 : 2).minimumScaleFactor(0.85)
                Text(player.artist.isEmpty ? "未知歌手" : player.artist)
                    .font(.system(size: layout.compact ? 10 : 11))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func playbackOptions(height: CGFloat) -> some View {
        HStack(spacing: 4) {
            option(symbol: player.mode.symbol, active: player.mode != .sequential, height: height,
                   label: "播放模式：\(player.mode.title)，轻点切换", action: player.cycleMode)
            option(symbol: "speedometer", active: player.playbackRate != 1, height: height,
                   label: "播放速度，\(player.playbackRate.formatted()) 倍", action: chooseSpeed)
            option(symbol: player.sleepTimerDeadline == nil ? "moon" : "moon.zzz.fill",
                   active: player.sleepTimerDeadline != nil, height: height, label: "睡眠定时", action: chooseSleep)
            option(symbol: "airplayaudio", active: true, height: height, label: "选择音频输出", action: chooseOutput)
            .disabled(player.isPreparing || choosingOutput)
        }
        .buttonStyle(.plain)
    }

    private func option(symbol: String, active: Bool, height: CGFloat, label: String,
                        action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: height < 36 ? 14 : 16, weight: .medium))
                .foregroundStyle(active ? AppPalette.accent : AppPalette.textSecondary)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 11))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .accessibilityLabel(label)
    }

    private func mainControls(height: CGFloat) -> some View {
        HStack(spacing: 5) {
            Button {
                player.previous()
                WKInterfaceDevice.current().play(.click)
            } label: { transportSymbol("backward.end.fill", height: height) }
                .accessibilityLabel("上一首")
            Button(action: player.togglePlayback) {
                Group {
                    if player.isPreparing { ProgressView().tint(AppPalette.controlForeground) }
                    else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: height < 46 ? 18 : 23, weight: .semibold))
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
                }
                .foregroundStyle(AppPalette.controlForeground)
                .frame(width: height, height: height)
                .background(AppPalette.accent, in: Circle())
                .contentShape(Circle())
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            nextControl(height: height)
        }
        .buttonStyle(.plain)
        .disabled(player.currentURL == nil)
    }

    private func transportSymbol(_ symbol: String, height: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: height < 46 ? 17 : 21, weight: .medium))
            .foregroundStyle(AppPalette.textPrimary)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func nextControl(height: CGFloat) -> some View {
        let control = Button {
            player.next()
            WKInterfaceDevice.current().play(.click)
        } label: { transportSymbol("forward.end.fill", height: height) }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("下一首")
        if #available(watchOS 11.0, *) {
            control.handGestureShortcut(.primaryAction,
                isEnabled: player.currentURL != nil && acceptsPrimaryGesture)
        } else { control }
    }

}

/// Keep volume changes local to this overlay so Crown input doesn't redraw
/// the playback page or disrupt the native control's focus.
private struct WatchVolumeFeedbackOverlay: View {
    @StateObject private var feedback = WatchVolumeFeedback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Position in the page's coordinates, independent of the physical
            // Crown and charging orientation. Keep the observer mounted.
            Color.clear
            if feedback.isVisible {
                volumeBar
                    .padding(.top, 40)
                    .padding(.trailing, 8)
                    .transition(reduceMotion ? .opacity :
                        .offset(x: 14).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: feedback.isVisible)
        .onAppear { feedback.setActive(isActive) }
        .onChange(of: isActive) { _, active in feedback.setActive(active) }
        .onDisappear { feedback.setActive(false) }
        #if DEBUG && targetEnvironment(simulator)
        .onChange(of: feedback.isVisible) { _, visible in
            WatchCrownDiagnostics.record(visible ? "volume-feedback-shown" : "volume-feedback-hidden")
        }
        .onChange(of: feedback.volume) { _, _ in
            WatchCrownDiagnostics.record("volume-feedback-updated")
        }
        .task(id: isActive) {
            guard isActive, ProcessInfo.processInfo.arguments.contains("-preview-volume-feedback") else { return }
            // Feed the same observer entry point without changing system volume
            // or playing audio. This fixture only verifies HUD rendering/timing.
            do {
                try await Task.sleep(for: .milliseconds(400))
                feedback.volumeDidChange(0.72)
                try await Task.sleep(for: .milliseconds(600))
                feedback.volumeDidChange(0.44)
                try await Task.sleep(for: .milliseconds(1800))
                feedback.volumeDidChange(0.68)
            } catch { return }
        }
        #endif
    }

    private var volumeBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(AppPalette.accent.opacity(0.24))
                Capsule().fill(AppPalette.accent)
                    .frame(height: geometry.size.height * CGFloat(feedback.volume))
            }
        }
        .frame(width: 5, height: 32)
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: feedback.volume)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue("百分之\(Int((feedback.volume * 100).rounded()))")
    }

}

private enum PlaybackDialog: Equatable {
    case speed, sleep
    var title: String { self == .speed ? "播放速度" : "睡眠定时" }
}

private struct WatchPlaybackLayout {
    let compact: Bool
    let tight: Bool
    let metadataHeight: CGFloat
    let optionsHeight: CGFloat
    let transportHeight: CGFloat
    let artworkSize: CGFloat
    let horizontalInset: CGFloat
    let bottomInset: CGFloat
    let spacing: CGFloat

    init(size: CGSize, minimumBottom: CGFloat = 0) {
        let profiles: [(metadata: CGFloat, options: CGFloat, transport: CGFloat, bottom: CGFloat)] =
            size.width < 180
            ? [(46, 40, 50, 12), (34, 34, 44, 10), (28, 30, 40, 8)]
            : [(64, 44, 64, 14), (46, 40, 50, 12), (34, 34, 44, 10), (28, 30, 40, 8)]
        let profile = profiles.first {
            $0.metadata + $0.options + $0.transport + max($0.bottom, minimumBottom) <= size.height
        } ?? (metadata: 28, options: 30, transport: 40, bottom: 8)
        metadataHeight = profile.metadata
        optionsHeight = profile.options
        transportHeight = profile.transport
        compact = metadataHeight < 60 || size.width < 180
        tight = metadataHeight <= 34
        artworkSize = tight ? metadataHeight : (compact ? 40 : 54)
        horizontalInset = size.width < 180 ? 12 : 14
        bottomInset = max(minimumBottom, profile.bottom)
        spacing = max(0, (size.height - metadataHeight - optionsHeight - transportHeight - bottomInset) / 2)
    }
}

/// The Crown changes system local output volume, without volume polling or
/// programmatic writes to system volume.
private struct WatchCrownVolumeControl: WKInterfaceObjectRepresentable {
    let isFocused: Bool
    let isPlaying: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WatchCrownDiagnostics.record("made")
        let control = WKInterfaceVolumeControl(origin: .local)
        control.setTintColor(UIColor(AppPalette.accent))
        return control
    }

    func updateWKInterfaceObject(_ object: WKInterfaceVolumeControl, context: Context) {
        WatchCrownDiagnostics.record("updated", focused: isFocused, playing: isPlaying)
        context.coordinator.update(object, focused: isFocused, isPlaying: isPlaying)
    }

    static func dismantleWKInterfaceObject(_ object: WKInterfaceVolumeControl, coordinator: Coordinator) {
        WatchCrownDiagnostics.record("dismantled")
        coordinator.stop(object)
    }

    @MainActor final class Coordinator {
        private var wantsFocus: Bool?
        private var wasPlaying = false
        private var focusTask: Task<Void, Never>?

        func update(_ control: WKInterfaceVolumeControl, focused: Bool, isPlaying: Bool) {
            // An initial paused session may ignore focus. Retry after real audio
            // activation completes, while respecting any presented system UI.
            let playbackStarted = isPlaying && !wasPlaying
            wasPlaying = isPlaying
            guard wantsFocus != focused || (focused && playbackStarted) else { return }
            wantsFocus = focused
            focusTask?.cancel()
            if focused {
                focusTask = Task { @MainActor [weak self, weak control] in
                    // Let the representable attach before requesting native focus.
                    await Task.yield()
                    guard !Task.isCancelled, self?.wantsFocus == true, let control else { return }
                    control.focus()
                    WatchCrownDiagnostics.record("focus-requested")
                }
            } else {
                control.resignFocus()
                WatchCrownDiagnostics.record("focus-resigned")
            }
        }

        func stop(_ control: WKInterfaceVolumeControl) {
            wantsFocus = false
            wasPlaying = false
            focusTask?.cancel()
            focusTask = nil
            control.resignFocus()
            WatchCrownDiagnostics.record("focus-resigned")
        }
    }
}
