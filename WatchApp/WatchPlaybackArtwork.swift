import SwiftUI
import UIKit

/// Keep one decoded image while its frame animates. Recreating UIImage for a
/// new GeometryReader size makes SwiftUI crossfade its contents during scaling.
struct WatchPlaybackArtwork: View {
    let title: String
    let data: Data?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    MusicArtwork(title: title)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: data) { image = data.flatMap { UIImage(data: $0) } }
    }
}
