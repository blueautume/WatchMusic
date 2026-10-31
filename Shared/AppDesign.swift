import SwiftUI
import UIKit

/// Shared visual language for the phone and watch apps.
enum AppPalette {
    #if os(watchOS)
    // watchOS uses a dark system appearance; universal asset luminosity
    // variants are not resolved consistently on supported Watch runtimes.
    static let accent = Color(red: 0.25, green: 0.63, blue: 1)
    static let background = Color(red: 0.035, green: 0.047, blue: 0.07)
    static let surface = Color(red: 0.075, green: 0.10, blue: 0.15)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.64, green: 0.70, blue: 0.79)
    #else
    static let accent = Color("AppAccent")
    static let background = Color("AppBackground")
    static let surface = Color("AppSurface")
    static let textPrimary = Color.primary
    static let textSecondary = Color("AppTextSecondary")
    #endif
    static let controlForeground = Color.white
    static let onAccent = controlForeground
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
                    LinearGradient(colors: [AppPalette.accent, Color(red: 0.07, green: 0.18, blue: 0.36), AppPalette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
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
        .accessibilityLabel(title.isEmpty ? L10n.text("音乐封面") : L10n.format("%@ 的封面", title))
    }
}
