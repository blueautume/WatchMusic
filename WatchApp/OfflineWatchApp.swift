import SwiftUI
import WatchKit

@main
struct OfflineWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var library = WatchLibrary.shared
    @StateObject private var player: WatchPlayer
    @StateObject private var display = WatchAppDisplay()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let engine = WatchPlayer()
        _player = StateObject(wrappedValue: engine)
    }
    var body: some Scene {
        WindowGroup {
            WatchAppSurface { rootView }
                .environmentObject(library).environmentObject(player).environmentObject(display)
                .tint(AppPalette.accent)
                .onAppear {
                    display.start(foreground: scenePhase == .active)
                    library.updateLANForeground(scenePhase == .active)
                    #if DEBUG
                    library.recordLANScenePhase(scenePhase == .background ? "background" : (scenePhase == .active ? "active" : "inactive"))
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { player.savePlaybackPosition() }
                    library.updateLANForeground(phase == .active)
                    display.setForeground(phase == .active)
                    #if DEBUG
                    library.recordLANScenePhase(phase == .background ? "background" : (phase == .active ? "active" : "inactive"))
                    if phase == .active { library.startLANPreviewIfRequested() }
                    #endif
                }
                #if DEBUG
                .task {
                    if scenePhase == .active { library.startLANPreviewIfRequested() }
                }
                #endif
        }
    }

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-preview-player") {
            FolderListView().task {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fixture = documents.appendingPathComponent("Music/UI预览/测试旋律.flac")
                if FileManager.default.fileExists(atPath: fixture.path) { player.prepareLayoutPreview(fixture) }
            }
        } else if ProcessInfo.processInfo.arguments.contains("-preview-lan-transfer") {
            LANTransferView(reception: LANReceptionStatus(fileName: "夜空中的旋律 · 夜跑歌单.flac", completedBytes: 6_300_000,
                                                        totalBytes: 10_000_000, fileIndex: 2, fileCount: 12, isSaving: false), cancel: {})
        } else { applicationView }
        #else
        applicationView
        #endif
    }

    @ViewBuilder private var applicationView: some View {
        if let reception = library.lanReception {
            LANTransferView(reception: reception, cancel: library.cancelLANTransfer)
        } else { FolderListView() }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let task = task as? WKWatchConnectivityRefreshBackgroundTask { WatchLibrary.shared.addBackgroundTask(task) }
            else if let task = task as? WKURLSessionRefreshBackgroundTask { WatchLibrary.shared.addURLSessionBackgroundTask(task) }
            else { task.setTaskCompletedWithSnapshot(false) }
        }
    }
}

struct FolderListView: View {
    @EnvironmentObject private var library: WatchLibrary
    @EnvironmentObject private var player: WatchPlayer
    @State private var newFolder = false
    @State private var libraryInfo = false
    @State private var previewTrackList = false
    @State private var previewPlayer = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var previewNavigationApplied = false
    #endif
    var body: some View {
        NavigationStack {
            List {
                if player.currentURL != nil {
                    NavigationLink(destination: NowPlayingView()) {
                        HStack(spacing: 9) {
                            MusicArtwork(title: player.title, data: player.artworkData)
                                .frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(player.isPlaying ? "正在聆听" : "继续聆听").font(.caption2).foregroundStyle(AppPalette.accent)
                                Text(player.title).font(.headline).lineLimit(1)
                            }
                        }
                    }.watchCardRow()
                }
                NavigationLink(destination: WatchTrackListView(folderName: nil)) {
                    Label("全部歌曲 · \(library.trackCount)", systemImage: "music.note.list").font(.headline)
                }.watchCardRow()
                if library.isReceiving && library.lanReception == nil {
                    HStack { ProgressView().controlSize(.mini); Text("正在保存歌曲…").font(.caption2) }.watchCardRow()
                }
                if library.folders.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.house.fill").font(.largeTitle).foregroundStyle(AppPalette.accent)
                        Text("暂无歌曲").font(.headline)
                        Text("从 iPhone 添加歌曲").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 10).watchCardRow()
                }
                Section("音乐目录") {
                    ForEach(library.folders) { folder in
                        NavigationLink(destination: WatchTrackListView(folderName: folder.name)) {
                            HStack(spacing: 9) {
                                Image(systemName: "folder.fill").foregroundStyle(AppPalette.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(folder.name).font(.headline).lineLimit(2)
                                    Text("\(folder.tracks.count) 首").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }.watchCardRow()
                    }
                    Button { newFolder = true } label: { Label("新建目录", systemImage: "folder.badge.plus") }.watchCardRow()
                }
                Button { libraryInfo = true } label: { Label("存储与连接", systemImage: "internaldrive") }.font(.caption).watchCardRow()
            }
            .watchPage(title: "随身音乐", showsBattery: true)
            .navigationDestination(isPresented: $previewTrackList) { WatchTrackListView(folderName: nil) }
            .navigationDestination(isPresented: $previewPlayer) { NowPlayingView() }
            .onAppear {
                library.refresh()
            }
            #if DEBUG && targetEnvironment(simulator)
            .task {
                guard !previewNavigationApplied else { return }
                previewNavigationApplied = true
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-preview-route-delay") {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                if arguments.contains("-preview-player") { previewPlayer = true }
                else if arguments.contains("-preview-track-list") { previewTrackList = true }
            }
            #endif
            .sheet(isPresented: $newFolder) {
                WatchAppSurface {
                    WatchNameEntry(title: "新建目录", initial: "", prompt: "目录名称") { name, done in library.createFolder(name, completion: done) }
                }
            }
            .sheet(isPresented: $libraryInfo) { WatchAppSurface { WatchLibraryInfoView() } }
        }
        .alert("音乐提示", isPresented: Binding(get: { library.errorMessage != nil || player.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(library.errorMessage ?? player.errorMessage ?? "") }
    }
}

private struct WatchTrackListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: WatchLibrary
    @EnvironmentObject private var player: WatchPlayer
    let folderName: String?
    @State private var search = ""
    @State private var showingPlayer = false
    @State private var managingTrack: WatchSongSelection?
    @State private var managingFolder = false
    private var tracks: [URL] {
        let items = folderName.flatMap { name in library.folders.first { $0.name == name }?.tracks } ?? (folderName == nil ? library.allTracks : [])
        return items.filter { search.isEmpty || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            TextField("搜索歌曲", text: $search).watchCardRow()
            if !tracks.isEmpty {
                Button {
                    if let first = tracks.first { player.play(first, in: tracks); showingPlayer = true }
                } label: { Label("播放全部 · \(tracks.count)", systemImage: "play.fill").foregroundStyle(AppPalette.accent) }.watchCardRow()
            }
            ForEach(tracks, id: \.self) { track in
                HStack(spacing: 5) {
                    Button { player.play(track, in: tracks); showingPlayer = true } label: {
                        HStack(spacing: 7) {
                            Image(systemName: player.currentURL == track ? "waveform" : "music.note")
                                .foregroundStyle(player.currentURL == track ? AppPalette.accent : .secondary).frame(width: 17)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.deletingPathExtension().lastPathComponent).font(.body).lineLimit(2)
                                Text(AudioFileFormat.format(for: track)?.displayName ?? "音频").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 44)
                    }.buttonStyle(.plain)
                    Button { managingTrack = WatchSongSelection(url: track) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("管理 \(track.deletingPathExtension().lastPathComponent)")
                }.watchCardRow()
            }
            if tracks.isEmpty { Text(search.isEmpty ? "此处还没有歌曲" : "没有匹配的歌曲").font(.caption).foregroundStyle(.secondary).watchCardRow() }
            if folderName != nil {
                Button { managingFolder = true } label: { Label("管理此目录", systemImage: "folder.badge.gearshape") }.font(.caption).watchCardRow()
            }
        }
        .watchPage(title: folderName ?? "全部歌曲", action: { dismiss() }, symbol: "chevron.left")
        .navigationDestination(isPresented: $showingPlayer) { NowPlayingView() }
        .sheet(item: $managingTrack) { item in WatchAppSurface { WatchTrackActionsView(track: item.url).modifier(WatchOperationErrorAlert()) } }
        .sheet(isPresented: $managingFolder) {
            WatchAppSurface {
                if let folderName { WatchFolderActionsView(folderName: folderName).modifier(WatchOperationErrorAlert()) }
            }
        }
        .onChange(of: library.folders.map(\.name)) { _, names in
            if let folderName, !names.contains(folderName) { dismiss() }
        }
    }
}

private struct WatchTrackActionsView: View {
    @EnvironmentObject private var library: WatchLibrary
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.dismiss) private var dismiss
    let track: URL
    @State private var renaming = false
    @State private var moving = false
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            List {
                Text(track.deletingPathExtension().lastPathComponent).font(.headline).watchCardRow()
                Text("\(AudioFileFormat.format(for: track)?.displayName ?? "音频") · \(track.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption2).foregroundStyle(.secondary).watchCardRow()
                Button { renaming = true } label: { Label("重命名", systemImage: "pencil") }.watchCardRow()
                Button { moving = true } label: { Label("移动到目录", systemImage: "folder") }.watchCardRow()
                Button(role: .destructive) { deleting = true } label: { Label("删除歌曲", systemImage: "trash") }.watchCardRow()
            }.watchPage(title: "管理歌曲", action: { dismiss() })
                .sheet(isPresented: $renaming) {
                    WatchAppSurface { WatchNameEntry(title: "重命名歌曲", initial: track.deletingPathExtension().lastPathComponent, prompt: "歌曲名称") { value, done in
                        library.renameTrack(track, to: value) { success in
                            done(success)
                            if success { if !FileManager.default.fileExists(atPath: track.path) { player.removeFromQueue(track) }; dismiss() }
                        }
                    } }
                }
                .sheet(isPresented: $moving) {
                    WatchAppSurface { NavigationStack {
                        List {
                            ForEach(library.folders.filter { $0.name != track.deletingLastPathComponent().lastPathComponent }) { folder in
                                Button(folder.name) {
                                    library.moveTrack(track, to: folder.name) { success in
                                        if success { if !FileManager.default.fileExists(atPath: track.path) { player.removeFromQueue(track) }; moving = false; dismiss() }
                                    }
                                }.watchCardRow()
                            }
                            if library.folders.count < 2 { Text("请先在音乐库中新建另一个目录。").font(.caption).foregroundStyle(.secondary).watchCardRow() }
                        }.watchPage(title: "移动到", action: { moving = false })
                    }.modifier(WatchOperationErrorAlert()) }
                }
                .confirmationDialog("从手表删除歌曲？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除", role: .destructive) {
                        library.deleteTrack(track) { success in
                            if success { if !FileManager.default.fileExists(atPath: track.path) { player.removeFromQueue(track) }; dismiss() }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: { Text("手机副本会保留。") }
        }
    }
}

private struct WatchFolderActionsView: View {
    @EnvironmentObject private var library: WatchLibrary
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.dismiss) private var dismiss
    let folderName: String
    @State private var renaming = false
    @State private var deleting = false
    private var tracks: [URL] { library.folders.first { $0.name == folderName }?.tracks ?? [] }
    var body: some View {
        NavigationStack {
            List {
                Text(folderName).font(.headline).watchCardRow()
                Button("重命名目录") { renaming = true }.watchCardRow()
                Button("删除目录", role: .destructive) { deleting = true }.watchCardRow()
            }.watchPage(title: "管理目录", action: { dismiss() })
                .sheet(isPresented: $renaming) {
                    WatchAppSurface { WatchNameEntry(title: "重命名目录", initial: folderName, prompt: "目录名称") { value, done in
                        let affectedTracks = tracks
                        library.renameFolder(folderName, to: value) { success in
                            done(success)
                            if success { affectedTracks.filter { !FileManager.default.fileExists(atPath: $0.path) }.forEach { player.removeFromQueue($0) }; dismiss() }
                        }
                    } }
                }
                .confirmationDialog("删除此目录及全部歌曲？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除目录", role: .destructive) {
                        let affectedTracks = tracks
                        library.deleteFolder(folderName) { success in
                            if success { affectedTracks.filter { !FileManager.default.fileExists(atPath: $0.path) }.forEach { player.removeFromQueue($0) }; dismiss() }
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
        }
    }
}

private struct WatchNameEntry: View {
    @EnvironmentObject private var library: WatchLibrary
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    let prompt: String
    let save: (String, @escaping (Bool) -> Void) -> Void
    @State private var value = ""
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                TextField(prompt, text: $value).watchCardRow()
                Button(saving ? "正在保存…" : "保存") {
                    saving = true
                    save(value) { success in saving = false; if success { dismiss() } }
                }.disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).watchCardRow()
            }.watchPage(title: title, action: { dismiss() })
                .onAppear { value = initial }
                .alert("无法保存", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                    Button("好", role: .cancel) { library.errorMessage = nil }
                } message: { Text(library.errorMessage ?? "") }
        }
    }
}

private struct WatchLibraryInfoView: View {
    @EnvironmentObject private var library: WatchLibrary
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("手表本地资料") {
                    Label("\(library.trackCount) 首歌曲", systemImage: "music.note.list").watchCardRow()
                    LabeledContent("音乐占用", value: watchBytes(library.totalBytes)).watchCardRow()
                    LabeledContent("设备可用", value: watchBytes(library.availableBytes)).watchCardRow()
                }
                Section("连接") {
                    Label(library.connectionStatus, systemImage: "iphone.and.arrow.forward").font(.caption).watchCardRow()
                    if let message = library.lastTransferMessage { Text(message).font(.caption2).foregroundStyle(AppPalette.accent).watchCardRow() }
                }
            }.watchPage(title: "存储与连接", action: { dismiss() })
        }
    }
}

/// Plain lists keep predictable navigation geometry. Each row supplies its own
/// rounded card and curved-screen margins rather than relying on list styling.
private extension View {
    func watchCardRow() -> some View {
        modifier(WatchCardRow())
    }
}

private struct WatchCardRow: ViewModifier {
    @Environment(\.watchPageInsets) private var pageInsets

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppPalette.surface)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            )
            .listRowInsets(EdgeInsets(top: 8, leading: max(14, pageInsets?.rowLeading ?? 14),
                                     bottom: 8, trailing: max(14, pageInsets?.rowTrailing ?? 14)))
    }
}

private func watchBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

private struct WatchSongSelection: Identifiable { let url: URL; var id: String { url.absoluteString } }

private struct WatchOperationErrorAlert: ViewModifier {
    @EnvironmentObject private var library: WatchLibrary
    @EnvironmentObject private var player: WatchPlayer
    func body(content: Content) -> some View {
        content.alert("操作提示", isPresented: Binding(get: { library.errorMessage != nil || player.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(library.errorMessage ?? player.errorMessage ?? "") }
    }
}
