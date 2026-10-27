import SwiftUI
import UIKit

/// Shared visual language for the phone and watch apps.
enum AppPalette {
    static let accent = Color(red: 1, green: 0.48, blue: 0.24)
    static let background = Color(red: 0.05, green: 0.063, blue: 0.082)
    static let surface = Color(red: 0.098, green: 0.122, blue: 0.157)
    static let textSecondary = Color(red: 0.60, green: 0.65, blue: 0.71)
}

struct MusicArtwork: View {
    let title: String
    var data: Data? = nil

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if let data, let artwork = UIImage(data: data) {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(red: 0.95, green: 0.36, blue: 0.17), Color(red: 0.35, green: 0.14, blue: 0.13), AppPalette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Color.black.opacity(0.56)).padding(side * 0.12)
                    ForEach(0..<4) { index in
                        Circle().stroke(.white.opacity(0.09), lineWidth: 1)
                            .padding(side * (0.16 + Double(index) * 0.06))
                    }
                    Circle().fill(AppPalette.accent).frame(width: side * 0.22, height: side * 0.22)
                    Image(systemName: "waveform").font(.system(size: side * 0.11, weight: .medium))
                        .foregroundStyle(.black.opacity(0.75))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityLabel(title.isEmpty ? "音乐封面" : "\(title) 的封面")
    }
}
