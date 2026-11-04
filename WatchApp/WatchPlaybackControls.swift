import SwiftUI
import WatchKit

/// Playback and navigation share the full local canvas; the page header owns
/// Back and the system-clock clearance without a second native toolbar inset.
struct NowPlayingView: View {
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @State private var activeDialog: PlaybackDialog?
    @State private var isOnScreen = false
    @State private var immersion = WatchImmersivePlayback()
    private struct ImmersionTaskID: Equatable {
        let request: WatchImmersivePlayback.IdleRequest?
        let canPresent: Bool
        let isInteractive: Bool
    }
    #if DEBUG && targetEnvironment(simulator)
    @State private var previewApplied = false
    @State private var previewImmersionCycleApplied = false
    #endif

    private var choosingOutput: Bool { player.isSelectingAudioOutput }

    private var acceptsCrownInput: Bool {
        isOnScreen && scenePhase == .active && activeDialog == nil && !choosingOutput && player.currentURL != nil
    }

    private var acceptsPrimaryGesture: Bool {
        isOnScreen && scenePhase == .active && activeDialog == nil && !choosingOutput && player.currentURL != nil
    }

    private var immersionAvailability: WatchImmersivePlayback.Availability {
        .init(isBackground: scenePhase == .background, hasTrack: player.currentURL != nil,
              isObstructed: activeDialog != nil || choosingOutput, isPreparing: player.isPreparing)
    }

    private var isInteractive: Bool { scenePhase == .active && !reducedLuminance }
    private var immersionAnimation: Animation? {
        isInteractive && !reduceMotion ? .easeInOut(duration: 0.55) : nil
    }

    var body: some View {
        let taskID = ImmersionTaskID(request: immersion.idleRequest,
                                    canPresent: isOnScreen && immersionAvailability == .ready,
                                    isInteractive: isInteractive)
        WatchPlaybackPageContent(
            acceptsPrimaryGesture: acceptsPrimaryGesture,
            isImmersive: immersion.isImmersive,
            showControls: registerInteraction,
            chooseSpeed: { activeDialog = .speed },
            chooseSleep: { activeDialog = .sleep },
            chooseOutput: { player.requestAudioOutput() }
        )
        .watchPage(title: "", action: closePlayback, symbol: "chevron.left", showsHeader: !immersion.isImmersive) {
            WatchPlaybackBackground(data: player.artworkData)
        }
        .contentShape(Rectangle())
        // Consume the first physical tap before it can activate a control or
        // Back. The visible cover retains the system primary-action shortcut.
        .highPriorityGesture(TapGesture().onEnded { registerInteraction() },
                             including: immersion.isImmersive ? .all : .subviews)
        .simultaneousGesture(TapGesture().onEnded { registerInteraction() },
                             including: immersion.isImmersive ? .subviews : .all)
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
            // Wrist-down can detach the view while keeping it frontmost.
            // Let SwiftUI cancel the task and keep the deadline for reappearance.
        }
        .onChange(of: immersionAvailability, initial: true) { _, availability in
            withAnimation(immersionAnimation) {
                immersion.updateAvailability(availability, at: WatchImmersivePlayback.now)
            }
        }
        .task(id: taskID) {
            guard taskID.canPresent, let request = taskID.request else { return }
            do {
                var remaining = request.deadline - WatchImmersivePlayback.now
                while remaining > 0 {
                    try await Task.sleep(for: .seconds(remaining))
                    remaining = request.deadline - WatchImmersivePlayback.now
                }
                guard !Task.isCancelled else { return }
                withAnimation(immersionAnimation) {
                    _ = immersion.enter(for: request, at: WatchImmersivePlayback.now)
                }
            } catch { return }
        }
        #if DEBUG && targetEnvironment(simulator)
        .onChange(of: immersion.isImmersive) { _, immersive in
            WatchCrownDiagnostics.record(immersive ? "immersive-entered" : "immersive-exited")
        }
        .onChange(of: immersion.idleRequest) { _, request in
            WatchCrownDiagnostics.record(request == nil ? "immersive-idle-stopped" : "immersive-idle-armed")
        }
        .task(id: immersion.isImmersive) {
            guard immersion.isImmersive, !previewImmersionCycleApplied,
                  ProcessInfo.processInfo.arguments.contains("-preview-immersion-cycle") else { return }
            previewImmersionCycleApplied = true
            do {
                try await Task.sleep(for: .seconds(3))
                guard isOnScreen else { return }
                // Exercise the same exit handler without synthesizing touch,
                // hand gestures, system volume changes, or audio playback.
                WatchCrownDiagnostics.record("immersive-preview-exit")
                registerInteraction()
            } catch { return }
        }
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

    private func registerInteraction() {
        withAnimation(immersionAnimation) { immersion.interact(at: WatchImmersivePlayback.now) }
    }

    private func closePlayback() {
        immersion.suspend()
        dismiss()
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
                Button(L10n.format("%@ 分钟", String(describing: minutes))) {
                    player.setSleepTimer(minutes: minutes)
                    activeDialog = nil
                }
            }
            if player.sleepTimerDeadline != nil {
                Button(L10n.text("关闭定时"), role: .destructive) {
                    player.setSleepTimer(minutes: nil)
                    activeDialog = nil
                }
            }
        case nil:
            EmptyView()
        }
        Button(L10n.text("取消"), role: .cancel) { activeDialog = nil }
    }
}

/// This child receives the local clock-clearance values injected by watchPage.
private struct WatchPlaybackPageContent: View {
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.watchPageInsets) private var pageInsets
    @Environment(\.watchContentViewport) private var viewport
    let acceptsPrimaryGesture: Bool
    let isImmersive: Bool
    let showControls: () -> Void
    let chooseSpeed: @MainActor () -> Void
    let chooseSleep: @MainActor () -> Void
    let chooseOutput: @MainActor () -> Void

    private var audioOutput: AudioOutputPresentation {
        #if DEBUG && targetEnvironment(simulator)
        // A rendering fixture only: this never changes the system audio route
        // or the player's playback/activation state.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-preview-audio-output"), arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "disconnected":
                return .disconnected
            case "headphones":
                return AudioOutputPresentation(ports: [AudioOutputPort(kind: .headphones, name: "Studio Headphones")])
            case "airpods":
                return AudioOutputPresentation(ports: [AudioOutputPort(kind: .bluetooth, name: "AirPods")])
            case "airpods-pro":
                return AudioOutputPresentation(ports: [AudioOutputPort(kind: .bluetooth, name: "AirPods Pro")])
            case "airpods-max":
                return AudioOutputPresentation(ports: [AudioOutputPort(kind: .bluetooth, name: "AirPods Max")])
            case "homepod":
                return AudioOutputPresentation(ports: [AudioOutputPort(kind: .airPlay, name: "Living Room HomePod")])
            case "unknown":
                return AudioOutputPresentation(ports: [AudioOutputPort(kind: .other, name: "Wireless Audio Device")])
            default: break
            }
        }
        #endif
        return player.audioOutput
    }

    private var outputAccessibilityValue: String {
        guard audioOutput.isConnected else { return L10n.text("未连接") }
        guard let deviceName = audioOutput.deviceName,
              !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return L10n.text("已连接") }
        return deviceName
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = WatchPlaybackLayout(size: geometry.size,
                minimumBottom: pageInsets?.bottomControlBottom ?? 0)
            let leading = max(layout.horizontalInset, pageInsets?.metadataLeading ?? 0)
            let trailing = max(layout.horizontalInset, pageInsets?.metadataTrailing ?? 0)
            let normalArtwork = CGRect(x: leading, y: (layout.metadataHeight - layout.artworkSize) / 2,
                                       width: layout.artworkSize, height: layout.artworkSize)
            let titleX = normalArtwork.maxX + (layout.compact ? 8 : 10)
            let normalTitle = CGRect(x: titleX, y: 0, width: max(0, geometry.size.width - trailing - titleX),
                                     height: layout.metadataHeight)
            ZStack(alignment: .topLeading) {
                VStack(spacing: layout.spacing) {
                    Color.clear.frame(height: layout.metadataHeight).allowsHitTesting(false).accessibilityHidden(true)
                    playbackOptions(height: layout.optionsHeight)
                    mainControls(height: layout.transportHeight)
                        .padding(.leading, max(0, (pageInsets?.bottomControlLeading ?? 0) - layout.horizontalInset))
                        .padding(.trailing, max(0, (pageInsets?.bottomControlTrailing ?? 0) - layout.horizontalInset))
                }
                .padding(.horizontal, layout.horizontalInset)
                .padding(.bottom, layout.bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(isImmersive ? 0 : 1)
                .scaleEffect(isImmersive ? 0.94 : 1, anchor: .bottom)
                .allowsHitTesting(!isImmersive)
                .accessibilityHidden(isImmersive)

                WatchArtworkCaptionLayout(size: geometry.size,
                    normalArtwork: normalArtwork, normalTitle: normalTitle,
                    isImmersive: isImmersive,
                    centeredVertically: viewport?.orientation.isLandscape ?? false,
                    clockFrame: pageInsets?.bodyClockFrame ?? .null) {
                    artworkControl(compact: layout.compact)
                    metadata(layout: layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: isImmersive ? .top : .center)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder private func artworkControl(compact: Bool) -> some View {
        let control = Button(action: advanceTrack) {
            WatchPlaybackArtwork(title: player.title, data: player.artworkData)
                .clipShape(RoundedRectangle(cornerRadius: isImmersive ? 18 : (compact ? 9 : 12)))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isImmersive)
        .accessibilityHidden(!isImmersive)
        .accessibilityLabel(L10n.text("下一首"))
        .accessibilityIdentifier("immersive-artwork")
        .accessibilityAction(named: L10n.text("播放控制"), showControls)
        if #available(watchOS 11.0, *) {
            control.handGestureShortcut(.primaryAction, isEnabled: isImmersive && acceptsPrimaryGesture)
        } else { control }
    }

    private func metadata(layout: WatchPlaybackLayout) -> some View {
            VStack(alignment: isImmersive ? .center : .leading, spacing: isImmersive ? 0 : 2) {
                Text(!isImmersive && player.isPreparing ? L10n.text("正在准备…") : player.title)
                    .font(.system(size: isImmersive ? 14 : (layout.compact ? 12 : 14), weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                    .lineLimit(isImmersive ? 2 : (layout.tight ? 1 : 2)).minimumScaleFactor(0.85)
                    .multilineTextAlignment(isImmersive ? .center : .leading)
                Text(player.artist.isEmpty ? L10n.text("未知歌手") : player.artist)
                    .font(.system(size: layout.compact ? 10 : 11))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)
                    .opacity(isImmersive ? 0 : 1)
                    .frame(height: isImmersive ? 0 : nil)
                    .accessibilityHidden(isImmersive)
            }
            .frame(maxWidth: .infinity, alignment: isImmersive ? .center : .leading)
    }

    private func playbackOptions(height: CGFloat) -> some View {
        HStack(spacing: 4) {
            option(symbol: player.mode.symbol, active: player.mode != .sequential, height: height,
                   label: L10n.format("播放模式：%@，轻点切换", String(describing: player.mode.title)), action: player.cycleMode)
            option(symbol: "speedometer", active: player.playbackRate != 1, height: height,
                   label: L10n.format("播放速度，%@ 倍", String(describing: player.playbackRate.formatted())), action: chooseSpeed)
            option(symbol: player.sleepTimerDeadline == nil ? "moon" : "moon.zzz.fill",
                   active: player.sleepTimerDeadline != nil, height: height, label: L10n.text("睡眠定时"), action: chooseSleep)
            option(symbol: audioOutput.symbol, active: audioOutput.isConnected, height: height,
                   label: L10n.text("选择音频输出"), action: chooseOutput)
                .accessibilityValue(outputAccessibilityValue)
                .disabled(player.isSelectingAudioOutput)
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
                .accessibilityLabel(L10n.text("上一首"))
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
            .accessibilityLabel(player.isPlaying ? L10n.text("暂停") : L10n.text("播放"))
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
        let control = Button(action: advanceTrack) { transportSymbol("forward.end.fill", height: height) }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel(L10n.text("下一首"))
        if #available(watchOS 11.0, *) {
            control.handGestureShortcut(.primaryAction,
                isEnabled: !isImmersive && acceptsPrimaryGesture)
        } else { control }
    }

    private func advanceTrack() {
        if !isImmersive { showControls() }
        player.next()
        WKInterfaceDevice.current().play(.click)
    }

}

/// Measure the actual caption before centering the landscape composition;
/// reserving two lines for a one-line title would leave it visibly top-heavy.
private struct WatchArtworkCaptionLayout: Layout {
    let size: CGSize
    let normalArtwork: CGRect
    let normalTitle: CGRect
    let isImmersive: Bool
    let centeredVertically: Bool
    let clockFrame: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = WatchImmersiveLayout(size: size, clockFrame: clockFrame,
                                         centeredVertically: centeredVertically)
        let titleHeight = centeredVertically && isImmersive
            ? subviews[1].sizeThatFits(ProposedViewSize(width: column.titleFrame.width, height: nil)).height : 34
        let immersive = WatchImmersiveLayout(size: size, clockFrame: clockFrame,
            titleHeight: titleHeight, centeredVertically: centeredVertically)
        let frames = isImmersive ? [immersive.artworkFrame, immersive.titleFrame] : [normalArtwork, normalTitle]
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.midX, y: bounds.minY + frame.midY),
                                  anchor: .center, proposal: ProposedViewSize(frame.size))
        }
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
        .accessibilityLabel(L10n.text("音量"))
        .accessibilityValue(L10n.format("百分之%@", String(describing: Int((feedback.volume * 100).rounded()))))
    }

}

private enum PlaybackDialog: Equatable {
    case speed, sleep
    var title: String { self == .speed ? L10n.text("播放速度") : L10n.text("睡眠定时") }
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
