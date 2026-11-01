import SwiftUI
import UIKit

/// A static backdrop uses the player's bounded thumbnail, never the audio file.
/// Its opaque base also conceals the native Crown volume control behind the page.
struct WatchPlaybackBackground: View {
    let data: Data?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @State private var artwork: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppPalette.background
                if !reduceTransparency && !reducedLuminance, let artwork {
                    let blurRadius: CGFloat = 12
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        // Extend the image beyond every edge before blurring.
                        .frame(width: geometry.size.width + blurRadius * 4,
                               height: geometry.size.height + blurRadius * 4)
                        .blur(radius: blurRadius, opaque: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(contrast == .increased ? 0.35 : 0.8)
                    LinearGradient(colors: [.black.opacity(0.68), .black.opacity(0.72), .black.opacity(0.82)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: data) {
            // Playback/volume updates reuse this image until the cover changes.
            artwork = data.flatMap { UIImage(data: $0) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
