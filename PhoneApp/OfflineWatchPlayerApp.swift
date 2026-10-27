import SwiftUI

@main
struct OfflineWatchPlayerApp: App {
    @StateObject private var library = PhoneLibrary()
    @StateObject private var player = MusicPlayer()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(AppPalette.accent)
        }
    }
}
