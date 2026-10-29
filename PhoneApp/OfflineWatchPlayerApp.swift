import SwiftUI

@main
struct OfflineWatchPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            PrivacyConsentGate()
                .tint(AppPalette.accent)
        }
    }
}

/// This subtree is constructed only after the current agreements are accepted.
/// In particular, PhoneLibrary must not activate WatchConnectivity at launch
/// while the first-use consent screen is still awaiting a decision.
struct AuthorizedPhoneContent: View {
    @StateObject private var library: PhoneLibrary
    @StateObject private var player: MusicPlayer
    private let withdrawConsent: () -> Void

    init(withdrawConsent: @escaping () -> Void) {
        self.withdrawConsent = withdrawConsent
        _player = StateObject(wrappedValue: MusicPlayer())
        _library = StateObject(wrappedValue: PhoneLibrary())
    }

    var body: some View {
        LibraryView()
            .environmentObject(library)
            .environmentObject(player)
            .environment(\.phonePlayer, player)
            .environment(\.withdrawPrivacyConsent, {
                player.stop()
                library.shutdownForPrivacyWithdrawal()
                withdrawConsent()
            })
    }
}
