import Combine
import SwiftUI

/// Actions need access to the player without subscribing the entire library to
/// playback updates. Only the small playback views observe MusicPlayer.
private struct PhonePlayerKey: EnvironmentKey {
    static let defaultValue: MusicPlayer? = nil
}

extension EnvironmentValues {
    var phonePlayer: MusicPlayer? {
        get { self[PhonePlayerKey.self] }
        set { self[PhonePlayerKey.self] = newValue }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @Environment(\.phonePlayer) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false
    @State private var showingSettings = false
    @State private var tab = 0
    @State private var hasPlayer = false
    @State private var tabBarClearance: CGFloat = 68

    private var isInSettings: Bool { tab == 1 && showingSettings }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                LibraryHome(openPlayer: { showingPlayer = true })
            }
            .tabItem { Label(L10n.text("音乐库"), systemImage: "music.note.list") }.tag(0)

            NavigationStack {
                TransfersView(openSettings: { showingSettings = true })
                    .navigationDestination(isPresented: $showingSettings) { PhoneSettingsView() }
            }
                .tabItem { Label(L10n.text("传输"), systemImage: "applewatch.and.arrow.forward") }
                .badge(library.pendingCount).tag(1)
        }
        .toolbarBackground(AppPalette.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .background {
            // Measurement stays behind content and never participates in the
            // overlay's hit region or the lists' pan gestures.
            TabBarLayoutReader { tabBarClearance = $0 ?? 68 }
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            // The overlay's only view is the actual 72pt bar. Offset moves its
            // drawing and hit region together, without a full-screen container.
            if !isInSettings {
                PinnedPlayerView(openPlayer: { showingPlayer = true })
                    .padding(.horizontal, PinnedPlayerLayout.horizontalMargin)
                    .offset(y: -(tabBarClearance + PinnedPlayerLayout.tabBarGap))
            }
        }
        .environment(\.pinnedPlayerClearance, hasPlayer && !isInSettings ? PinnedPlayerLayout.listClearance : 0)
        .onReceive(playerPresence) { hasPlayer = $0 }
        .overlay(alignment: .top) { TransferSummaryToast() }
        .overlay { PhonePlayerErrorPresenter(isShowingPlayer: showingPlayer) }
        .sheet(isPresented: $showingPlayer) {
            PhoneNowPlayingView().presentationDragIndicator(.visible)
        }
        .alert(L10n.text("提示"), isPresented: Binding(
            get: { !showingPlayer && library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button(L10n.text("好"), role: .cancel) { library.errorMessage = nil }
        } message: { Text(L10n.message(library.errorMessage ?? "")) }
        .onChange(of: scenePhase, initial: true) { previous, phase in
            if previous == .active && phase != .active { player?.savePlaybackPosition() }
            player?.setApplicationInBackground(phase == .background)
            switch phase {
            case .active:
                library.sceneDidBecomeActive()
                library.refreshConnection()
                library.refreshFolders()
                #if DEBUG
                library.startLANProbeIfRequested()
                #endif
            case .background: library.sceneDidEnterBackground()
            case .inactive: library.sceneDidBecomeInactive()
            @unknown default: break
            }
        }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-preview-lan") { tab = 1 }
            #if targetEnvironment(simulator)
            library.prepareTransferListPreviewIfRequested()
            if arguments.contains("-preview-transfers-in-progress") || arguments.contains("-preview-transfers-completed") {
                tab = 1
            }
            if ["-preview-settings", "-preview-about", "-preview-agreements",
                "-preview-privacy-document", "-preview-terms-document", "-preview-support-document"]
                .contains(where: arguments.contains) {
                tab = 1; showingSettings = true
            }
            #endif
            if arguments.contains("-preview-player") || arguments.contains("-preview-queue") || arguments.contains("-preview-player-bottom"), let track = library.allTracks.first {
                player?.prepareLayoutPreview(track.url)
                showingPlayer = true
            } else if arguments.contains("-preview-pinned-player"), let track = library.allTracks.first {
                player?.prepareLayoutPreview(track.url)
            }
        }
        #endif
    }

    /// Subscribe only to presence changes, so playback ticks and play/pause do
    /// not reconfigure navigation, list spacing or an open menu.
    private var playerPresence: AnyPublisher<Bool, Never> {
        guard let player else { return Just(false).eraseToAnyPublisher() }
        return player.$currentURL.map { $0 != nil }.removeDuplicates().eraseToAnyPublisher()
    }
}

private struct TransferSummaryToast: View {
    @EnvironmentObject private var library: PhoneLibrary
    @State private var summary: String?

    var body: some View {
        Group {
            if let summary {
                Text(L10n.message(summary))
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(AppPalette.textPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 20).padding(.top, 8)
            }
        }
        .allowsHitTesting(false)
        .onReceive(library.$transferSummary) { summary = $0 }
        .task(id: summary) {
            guard summary != nil else { return }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) }
            catch { return }
            summary = nil
        }
    }
}

private struct PhonePlayerErrorPresenter: View {
    @EnvironmentObject private var player: MusicPlayer
    let isShowingPlayer: Bool

    var body: some View {
        Color.clear.allowsHitTesting(false)
            .alert(L10n.text("提示"), isPresented: Binding(
                get: { !isShowingPlayer && player.errorMessage != nil },
                set: { if !$0 { player.errorMessage = nil } }
            )) {
                Button(L10n.text("好"), role: .cancel) { player.errorMessage = nil }
            } message: { Text(L10n.message(player.errorMessage ?? "")) }
    }
}

func phoneTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let value = Int(seconds)
    return value >= 3600
        ? String(format: "%d:%02d:%02d", value / 3_600, (value % 3_600) / 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}
