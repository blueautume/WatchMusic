import SwiftUI
import UIKit

/// The bar overlays content; only scrollable lists reserve a matching tail so
/// their final row can still be brought above it.
enum PinnedPlayerLayout {
    static let height: CGFloat = 72
    static let horizontalMargin: CGFloat = 16
    static let tabBarGap: CGFloat = 8
    static let listClearance = height + tabBarGap + 8
}

private struct PinnedPlayerClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var pinnedPlayerClearance: CGFloat {
        get { self[PinnedPlayerClearanceKey.self] }
        set { self[PinnedPlayerClearanceKey.self] = newValue }
    }
}

struct PinnedPlayerView: View {
    @EnvironmentObject private var player: MusicPlayer
    let openPlayer: () -> Void

    var body: some View {
        if player.currentURL != nil {
            playbackBar
                .frame(maxWidth: .infinity)
                .frame(height: PinnedPlayerLayout.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(AppPalette.textPrimary.opacity(0.10), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.text("播放控制"))
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 4) {
            Button(action: openPlayer) {
                HStack(spacing: 10) {
                    MusicArtwork(title: player.title, data: player.artworkData)
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppPalette.textPrimary).lineLimit(1)
                        if !player.artist.isEmpty {
                            Text(player.artist).font(.caption).foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(L10n.format("打开播放器：%@", player.title))
            Button(action: player.previous) {
                Image(systemName: "backward.end.fill").frame(width: 44, height: 44)
            }.accessibilityLabel(L10n.text("上一首"))
            Button(action: player.togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3).frame(width: 44, height: 44)
            }.accessibilityLabel(player.isPlaying ? L10n.text("暂停") : L10n.text("播放"))
            Button(action: player.next) {
                Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
            }.accessibilityLabel(L10n.text("下一首"))
        }
        .buttonStyle(.plain).foregroundStyle(AppPalette.accent).padding(.horizontal, 12)
    }
}

/// Reads the system tab bar after layout rather than assuming its height. This
/// also follows rotation and the floating tab bar on newer iOS releases.
struct TabBarLayoutReader: UIViewControllerRepresentable {
    let onChange: (CGFloat?) -> Void

    func makeUIViewController(context: Context) -> TabBarLayoutObserver {
        TabBarLayoutObserver(onChange: onChange)
    }

    func updateUIViewController(_ controller: TabBarLayoutObserver, context: Context) {
        controller.onChange = onChange
        controller.requestMeasurement()
    }
}

final class TabBarLayoutObserver: UIViewController {
    var onChange: (CGFloat?) -> Void
    private var measurementPending = false
    private var reportedClearance: CGFloat?

    init(onChange: @escaping (CGFloat?) -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestMeasurement()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        requestMeasurement()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        requestMeasurement()
    }

    func requestMeasurement() {
        guard !measurementPending else { return }
        measurementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementPending = false
            let tabBar = self.view.window?.rootViewController.flatMap { self.findTabBar(in: $0) }
            let clearance = tabBar.map {
                max(0, self.view.bounds.height - self.view.convert($0.bounds, from: $0).minY)
            }
            guard self.reportedClearance != clearance else { return }
            self.reportedClearance = clearance
            self.onChange(clearance)
        }
    }

    private func findTabBar(in controller: UIViewController) -> UITabBar? {
        if let controller = controller as? UITabBarController,
           !controller.tabBar.isHidden, controller.tabBar.window != nil {
            return controller.tabBar
        }
        for child in controller.children.reversed() {
            if let tabBar = findTabBar(in: child) { return tabBar }
        }
        return nil
    }
}
