import SwiftUI
import WatchKit

@main
struct OfflineWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var library = WatchLibrary.shared
    @StateObject private var player = WatchPlayer()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            rootView.environmentObject(library).environmentObject(player)
                .tint(AppPalette.accent).preferredColorScheme(.dark)
                .onAppear {
                    library.updateLANForeground(scenePhase != .background)
                    #if DEBUG
                    library.recordLANScenePhase(scenePhase == .background ? "background" : (scenePhase == .active ? "active" : "inactive"))
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    library.updateLANForeground(phase != .background)
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
            NavigationStack { NowPlayingView() }.task {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fixture = documents.appendingPathComponent("Music/UI预览/测试旋律.flac")
                if FileManager.default.fileExists(atPath: fixture.path) { player.prepareLayoutPreview(fixture) }
            }
        } else if ProcessInfo.processInfo.arguments.contains("-preview-lan-transfer") {
            LANTransferView(reception: LANReceptionStatus(fileName: "夜空中的旋律 · 夜跑歌单.flac", completedBytes: 6_300_000,
                                                        totalBytes: 10_000_000, fileIndex: 2, fileCount: 12, isSaving: false), cancel: {},
                            previewOrientation: ProcessInfo.processInfo.arguments.contains("-preview-landscape") ? .landscapeRight : .portrait)
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
                    }.listRowBackground(AppPalette.surface)
                }
                NavigationLink(destination: WatchTrackListView(folderName: nil)) {
                    Label("全部歌曲 · \(library.trackCount)", systemImage: "music.note.list").font(.headline)
                }.listRowBackground(AppPalette.surface)
                if library.isReceiving && library.lanReception == nil {
                    HStack { ProgressView().controlSize(.mini); Text("正在保存歌曲…").font(.caption2) }
                }
                if library.folders.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.house.fill").font(.largeTitle).foregroundStyle(AppPalette.accent)
                        Text("暂无歌曲").font(.headline)
                        Text("从 iPhone 添加歌曲").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 10).listRowBackground(Color.clear)
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
                        }.listRowBackground(AppPalette.surface)
                    }
                    Button { newFolder = true } label: { Label("新建目录", systemImage: "folder.badge.plus") }
                }
                Button { libraryInfo = true } label: { Label("存储与连接", systemImage: "internaldrive") }.font(.caption)
            }
            .navigationTitle("随身音乐")
            .onAppear { library.refresh() }
            .sheet(isPresented: $newFolder) {
                WatchNameEntry(title: "新建目录", initial: "", prompt: "目录名称") { name, done in library.createFolder(name, completion: done) }
            }
            .sheet(isPresented: $libraryInfo) { WatchLibraryInfoView() }
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
            if !tracks.isEmpty {
                Button {
                    if let first = tracks.first { player.play(first, in: tracks); showingPlayer = true }
                } label: { Label("播放全部 · \(tracks.count)", systemImage: "play.fill").foregroundStyle(AppPalette.accent) }
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
                }.listRowBackground(AppPalette.surface)
            }
            if tracks.isEmpty { Text(search.isEmpty ? "此处还没有歌曲" : "没有匹配的歌曲").font(.caption).foregroundStyle(.secondary) }
            if folderName != nil {
                Button { managingFolder = true } label: { Label("管理此目录", systemImage: "folder.badge.gearshape") }.font(.caption)
            }
        }
        .navigationTitle(folderName ?? "全部歌曲")
        .searchable(text: $search, prompt: "搜索歌曲")
        .navigationDestination(isPresented: $showingPlayer) { NowPlayingView() }
        .sheet(item: $managingTrack) { item in WatchTrackActionsView(track: item.url).modifier(WatchOperationErrorAlert()) }
        .sheet(isPresented: $managingFolder) {
            if let folderName { WatchFolderActionsView(folderName: folderName).modifier(WatchOperationErrorAlert()) }
        }
        .onChange(of: library.folders.map(\.name)) { _, names in
            if let folderName, !names.contains(folderName) { dismiss() }
        }
    }
}

/// A single playback surface keeps every primary action inside the safe area.
struct NowPlayingView: View {
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var showingQueue = false
    @State private var showingSettings = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 180 || geometry.size.height < 185
            let controlSize: CGFloat = compact ? 44 : 56
            VStack(spacing: compact ? 5 : 9) {
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("返回音乐库")
                    Spacer(minLength: 0)
                    Button { showingQueue = true } label: {
                        Image(systemName: "list.bullet").font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("播放队列")
                    Button { showingSettings = true } label: {
                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("播放设置")
                }.foregroundStyle(.secondary)

                HStack(spacing: 9) {
                    MusicArtwork(title: player.title, data: player.artworkData)
                        .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.isPreparing ? "正在准备…" : player.title)
                            .font(.system(size: compact ? 13 : 15, weight: .semibold))
                            .lineLimit(2).minimumScaleFactor(0.85)
                        if !compact, !player.artist.isEmpty {
                            Text(player.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)

                HStack(spacing: compact ? 3 : 8) {
                    Button { player.previous(); WKInterfaceDevice.current().play(.click) } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: compact ? 20 : 22))
                            .frame(maxWidth: .infinity, minHeight: controlSize).contentShape(Rectangle())
                    }.accessibilityLabel("上一首")
                    Button(action: player.togglePlayback) {
                        Group {
                            if player.isPreparing { ProgressView().tint(.black) }
                            else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: compact ? 21 : 25, weight: .semibold)) }
                        }.foregroundStyle(.black).frame(width: controlSize, height: controlSize)
                            .background(AppPalette.accent, in: Circle()).contentShape(Circle())
                    }.accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                    nextButton(size: controlSize, compact: compact)
                }.disabled(player.currentURL == nil).frame(height: controlSize)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, compact ? 12 : 16)
        }
        .background(AppPalette.background)
        .navigationTitle("").toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingQueue) { WatchQueueDetailView().modifier(WatchOperationErrorAlert()) }
        .sheet(isPresented: $showingSettings) { WatchPlaybackSettingsView().modifier(WatchOperationErrorAlert()) }
    }

    @ViewBuilder private func nextButton(size: CGFloat, compact: Bool) -> some View {
        if #available(watchOS 11.0, *) {
            nextControl(size: size, compact: compact)
                .handGestureShortcut(.primaryAction, isEnabled: player.currentURL != nil && !showingQueue && !showingSettings)
        } else { nextControl(size: size, compact: compact) }
    }
    private func nextControl(size: CGFloat, compact: Bool) -> some View {
        Button { player.next(); WKInterfaceDevice.current().play(.click) } label: {
            Image(systemName: "forward.end.fill").font(.system(size: compact ? 20 : 22))
                .frame(maxWidth: .infinity, minHeight: size).contentShape(Rectangle())
        }.accessibilityLabel("下一首")
    }
}

private struct WatchQueueDetailView: View {
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int?
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.element) { index, url in
                    HStack {
                        Button { player.playQueueItem(at: index); dismiss() } label: {
                            Text(url.deletingPathExtension().lastPathComponent).lineLimit(2)
                                .foregroundStyle(player.currentURL == url ? AppPalette.accent : .white)
                        }.buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        Button { selectedIndex = index } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("调整队列")
                    }
                }
                if player.queue.isEmpty { Text("还没有播放队列").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("播放队列")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .confirmationDialog("调整播放队列", isPresented: Binding(get: { selectedIndex != nil }, set: { if !$0 { selectedIndex = nil } }), titleVisibility: .visible) {
                    Button("移到最前") { if let index = selectedIndex, player.queue.indices.contains(index) { player.moveQueueItems(from: IndexSet(integer: index), to: 0) }; selectedIndex = nil }
                    Button("从队列移除", role: .destructive) { if let index = selectedIndex { player.removeQueueItem(at: index) }; selectedIndex = nil }
                    Button("取消", role: .cancel) { selectedIndex = nil }
                }
        }
    }
}

private struct WatchPlaybackSettingsView: View {
    @EnvironmentObject private var player: WatchPlayer
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("播放方式") {
                    Button(action: player.cycleMode) { Label(player.mode.title, systemImage: player.mode.symbol) }
                    Picker("播放速度", selection: Binding(get: { player.playbackRate }, set: player.setRate)) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                    NavigationLink(destination: WatchQueueDetailView()) { Label("播放队列", systemImage: "list.bullet") }
                }
                Section("音频输出") {
                    Button(action: player.requestAudioOutput) { Label("连接音频输出", systemImage: "headphones") }
                    Text(player.routeDescription).font(.caption2).foregroundStyle(AppPalette.accent)
                    WatchSystemVolume().frame(height: 44).accessibilityLabel("手表系统音量")
                }
                Section("睡眠定时") {
                    if let remaining = player.sleepRemaining {
                        Text("将在 \(watchTime(remaining)) 后暂停").foregroundStyle(AppPalette.accent)
                        Button("取消定时", role: .destructive) { player.setSleepTimer(minutes: nil) }
                    }
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) 分钟后暂停") { player.setSleepTimer(minutes: minutes) } }
                }
                Section {
                    Button("停止播放", role: .destructive) { player.stop(); dismiss() }
                }
            }.navigationTitle("播放设置")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct WatchSystemVolume: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        control.setTintColor(UIColor(AppPalette.accent))
        return control
    }
    func updateWKInterfaceObject(_ object: WKInterfaceVolumeControl, context: Context) {}
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
                Text(track.deletingPathExtension().lastPathComponent).font(.headline)
                Text("\(AudioFileFormat.format(for: track)?.displayName ?? "音频") · \(track.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption2).foregroundStyle(.secondary)
                Button { renaming = true } label: { Label("重命名", systemImage: "pencil") }
                Button { moving = true } label: { Label("移动到目录", systemImage: "folder") }
                Button(role: .destructive) { deleting = true } label: { Label("删除歌曲", systemImage: "trash") }
            }.navigationTitle("管理歌曲")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $renaming) {
                    WatchNameEntry(title: "重命名歌曲", initial: track.deletingPathExtension().lastPathComponent, prompt: "歌曲名称") { value, done in
                        library.renameTrack(track, to: value) { success in
                            done(success)
                            if success { if !FileManager.default.fileExists(atPath: track.path) { player.removeFromQueue(track) }; dismiss() }
                        }
                    }
                }
                .sheet(isPresented: $moving) {
                    NavigationStack {
                        List {
                            ForEach(library.folders.filter { $0.name != track.deletingLastPathComponent().lastPathComponent }) { folder in
                                Button(folder.name) {
                                    library.moveTrack(track, to: folder.name) { success in
                                        if success { if !FileManager.default.fileExists(atPath: track.path) { player.removeFromQueue(track) }; moving = false; dismiss() }
                                    }
                                }
                            }
                            if library.folders.count < 2 { Text("请先在音乐库中新建另一个目录。").font(.caption).foregroundStyle(.secondary) }
                        }.navigationTitle("移动到")
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { moving = false } } }
                    }.modifier(WatchOperationErrorAlert())
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
                Text(folderName).font(.headline)
                Button("重命名目录") { renaming = true }
                Button("删除目录", role: .destructive) { deleting = true }
            }.navigationTitle("管理目录")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $renaming) {
                    WatchNameEntry(title: "重命名目录", initial: folderName, prompt: "目录名称") { value, done in
                        let affectedTracks = tracks
                        library.renameFolder(folderName, to: value) { success in
                            done(success)
                            if success { affectedTracks.filter { !FileManager.default.fileExists(atPath: $0.path) }.forEach { player.removeFromQueue($0) }; dismiss() }
                        }
                    }
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
                TextField(prompt, text: $value)
                Button(saving ? "正在保存…" : "保存") {
                    saving = true
                    save(value) { success in saving = false; if success { dismiss() } }
                }.disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.navigationTitle(title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
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
                    Label("\(library.trackCount) 首歌曲", systemImage: "music.note.list")
                    LabeledContent("音乐占用", value: watchBytes(library.totalBytes))
                    LabeledContent("设备可用", value: watchBytes(library.availableBytes))
                }
                Section("连接") {
                    Label(library.connectionStatus, systemImage: "iphone.and.arrow.forward").font(.caption)
                    if let message = library.lastTransferMessage { Text(message).font(.caption2).foregroundStyle(AppPalette.accent) }
                }
            }.navigationTitle("存储与连接")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private func watchTime(_ value: TimeInterval) -> String {
    guard value.isFinite else { return "0:00" }
    let seconds = max(0, Int(value))
    return seconds >= 3_600 ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
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
