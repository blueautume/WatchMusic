import SwiftUI

@main
struct OfflineWatchPlayerApp: App {
    @StateObject private var library: PhoneLibrary
    @StateObject private var player: MusicPlayer

    init() {
        let engine = MusicPlayer()
        PlaybackControlCenter.shared.configure(player: engine)
        _player = StateObject(wrappedValue: engine)
        _library = StateObject(wrappedValue: PhoneLibrary())
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(AppPalette.accent)
                .onAppear { PlaybackControlCenter.shared.configure(player: player) }
        }
    }
}
