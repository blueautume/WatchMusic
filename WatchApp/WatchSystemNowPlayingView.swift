import SwiftUI
import WatchKit

/// Keep the system media controls as the sheet's only content. The system
/// selects the active source and owns playback, volume, and media gestures.
struct WatchSystemNowPlayingView: View {
    var body: some View {
        NowPlayingView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Preserve the sheet's native dismissal control.
            .toolbar(.visible, for: .navigationBar)
    }
}
