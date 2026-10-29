import SwiftUI

struct LibraryHome: View {
    @EnvironmentObject private var library: PhoneLibrary
    @Environment(\.phonePlayer) private var player
    @Environment(\.pinnedPlayerClearance) private var playerClearance
    let openPlayer: () -> Void
    let openSettings: () -> Void
    @State private var search = ""
    @State private var showCreate = false
    @State private var folderName = ""
    @State private var editingFolder: PhoneFolder?
    @State private var deletingFolder: PhoneFolder?
    @State private var previewFolder: PhoneFolder?

    private var folders: [PhoneFolder] {
        library.folders.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if folders.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "还没有目录" : "没有找到目录", systemImage: "folder")
                } actions: {
                    if search.isEmpty {
                        Button("新建目录", systemImage: "folder.badge.plus") {
                            folderName = ""; showCreate = true
                        }.buttonStyle(.borderedProminent)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(folders) { folder in
                NavigationLink(value: folder) {
                    FolderRow(folder: folder, count: library.tracks(in: folder).count)
                }
                .listRowBackground(AppPalette.surface)
                .contextMenu {
                    Button("发送目录到手表", systemImage: "applewatch.and.arrow.forward") {
                        library.send(library.tracks(in: folder))
                    }.disabled(library.isImporting || library.tracks(in: folder).isEmpty)
                    Button("重命名", systemImage: "pencil") {
                        folderName = folder.name; editingFolder = folder
                    }
                    Button("删除目录", systemImage: "trash", role: .destructive) {
                        deletingFolder = folder
                    }.disabled(library.isImporting)
                }
            }
            if playerClearance > 0 { PinnedPlayerListSpace(height: playerClearance) }
        }
        .foregroundStyle(AppPalette.textPrimary)
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle("音乐库")
        .navigationDestination(for: PhoneFolder.self) { folder in
            FolderDetailView(folder: folder, openPlayer: openPlayer)
        }
        .navigationDestination(item: $previewFolder) { folder in
            FolderDetailView(folder: folder, openPlayer: openPlayer)
        }
        .searchable(text: $search, prompt: "搜索目录")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openSettings) { Image(systemName: "gearshape") }
                .accessibilityLabel("设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    folderName = ""; showCreate = true
                } label: { Image(systemName: "folder.badge.plus") }
                .accessibilityLabel("新建目录")
            }
        }
        .alert("新建目录", isPresented: $showCreate) {
            TextField("目录名称", text: $folderName)
            Button("创建") { _ = library.createFolder(folderName) }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名目录", isPresented: Binding(
            get: { editingFolder != nil }, set: { if !$0 { editingFolder = nil } }
        )) {
            TextField("目录名称", text: $folderName)
            Button("保存") {
                if let folder = editingFolder {
                    let tracks = library.tracks(in: folder)
                    if library.renameFolder(folder, to: folderName) { cleanPlayerQueue(tracks) }
                }
                editingFolder = nil
            }
            Button("取消", role: .cancel) { editingFolder = nil }
        }
        .confirmationDialog("删除“\(deletingFolder?.name ?? "")”？", isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }
        ), titleVisibility: .visible) {
            Button("删除手机中的目录和歌曲", role: .destructive) {
                if let folder = deletingFolder {
                    let tracks = library.tracks(in: folder)
                    if library.deleteFolder(folder) { cleanPlayerQueue(tracks) }
                }
                deletingFolder = nil
            }
            Button("取消", role: .cancel) { deletingFolder = nil }
        } message: { Text("手表上的歌曲会保留。") }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-preview-folder") || arguments.contains("-preview-folder-selection") {
                previewFolder = library.folders.first
            }
        }
        #endif
    }

    private func cleanPlayerQueue(_ tracks: [PhoneTrack]) {
        tracks.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
            .forEach { player?.removeFromQueue($0.url) }
    }
}

private struct FolderRow: View {
    let folder: PhoneFolder
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.title2).foregroundStyle(AppPalette.accent)
                .frame(width: 44, height: 48)
            Text(folder.name).font(.headline).lineLimit(2)
            Spacer(minLength: 8)
            Text("\(count) 首").font(.caption).foregroundStyle(AppPalette.textSecondary)
        }.padding(.vertical, 4)
    }
}

struct FolderDetailView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @Environment(\.phonePlayer) private var player
    @Environment(\.pinnedPlayerClearance) private var playerClearance
    let folder: PhoneFolder
    let openPlayer: () -> Void
    @State private var importing = false
    @State private var search = ""
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()

    private var tracks: [PhoneTrack] {
        library.tracks(in: folder).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var selectedTracks: [PhoneTrack] { tracks.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        List {
            if !tracks.isEmpty && !isSelecting {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            guard let first = tracks.first else { return }
                            player?.play(first.url, in: tracks.map(\.url)); openPlayer()
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.plain).foregroundStyle(AppPalette.controlForeground)
                        .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 14))
                        Button { library.send(tracks) } label: {
                            Image(systemName: "applewatch.and.arrow.forward")
                                .font(.title3).frame(width: 56, height: 48)
                        }
                        .buttonStyle(.plain).foregroundStyle(AppPalette.accent)
                        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                        .disabled(library.isImporting).accessibilityLabel("发送此目录到手表")
                    }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            Section {
                if tracks.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "还没有音乐" : "没有找到歌曲", systemImage: "music.note")
                    } actions: {
                        if search.isEmpty {
                            Button("导入音乐", systemImage: "plus") { importing = true }
                                .buttonStyle(.borderedProminent).disabled(library.isImporting)
                        }
                    }.listRowBackground(Color.clear)
                }
                ForEach(tracks) { track in
                    MusicTrackRow(
                        track: track, queue: tracks, library: library,
                        folders: library.folders, isImporting: library.isImporting,
                        isUpdatingTransferControls: library.isUpdatingTransferControls,
                        isTransferred: library.isFullyTransferred(track),
                        isSelecting: isSelecting, isSelected: selectedIDs.contains(track.id),
                        openPlayer: openPlayer,
                        toggleSelection: { toggleSelection(track) },
                        beginSelection: { isSelecting = true; selectedIDs.insert(track.id) }
                    )
                }
            } header: { Text("\(tracks.count) 首") }
                .listRowBackground(AppPalette.surface)
            if library.isImporting {
                ProgressView(library.importMessage, value: library.importProgress)
                    .font(.caption).tint(AppPalette.accent).listRowBackground(AppPalette.surface)
            }
            if let summary = library.importSummary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(AppPalette.textSecondary)
                    .listRowBackground(Color.clear)
            }
            if playerClearance > 0 { PinnedPlayerListSpace(height: playerClearance) }
        }
        .foregroundStyle(AppPalette.textPrimary)
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle(folder.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索此目录")
        .onChange(of: tracks.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button(selectedIDs.count == tracks.count ? "取消全选" : "全选") {
                        selectedIDs = selectedIDs.count == tracks.count ? [] : Set(tracks.map(\.id))
                    }.disabled(tracks.isEmpty)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    TrackSelectionMenu(
                        library: library, tracks: selectedTracks,
                        folders: library.folders, isImporting: library.isImporting,
                        isUpdatingTransferControls: library.isUpdatingTransferControls
                    ) { processed in
                        selectedIDs.subtract(processed)
                        if selectedIDs.isEmpty { isSelecting = false }
                    }
                    Button("完成") { isSelecting = false; selectedIDs.removeAll() }
                } else {
                    Button { importing = true } label: { Image(systemName: "plus") }
                        .disabled(library.isImporting).accessibilityLabel("导入音乐")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AudioFileFormat.importContentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls, into: folder)
            case .failure(let error): library.errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-preview-folder-selection") {
                isSelecting = true; selectedIDs = Set(tracks.prefix(2).map(\.id))
            }
        }
        #endif
    }

    private func toggleSelection(_ track: PhoneTrack) {
        if !selectedIDs.insert(track.id).inserted { selectedIDs.remove(track.id) }
    }
}

/// Menu state lives outside playback/progress observers so an open menu remains
/// stable while the current song or a transfer updates.
private struct TrackSelectionMenu: View {
    @Environment(\.phonePlayer) private var player
    let library: PhoneLibrary
    let tracks: [PhoneTrack]
    let folders: [PhoneFolder]
    let isImporting: Bool
    let isUpdatingTransferControls: Bool
    let processed: (Set<String>) -> Void
    @State private var moving = false
    @State private var deleting = false
    @State private var isSending = false

    var body: some View {
        Menu {
            Button("发送到手表", systemImage: "applewatch.and.arrow.forward") {
                isSending = true
                library.send(tracks, retryPending: true) { ids in
                    isSending = false; processed(ids)
                }
            }
            Button("移动到目录", systemImage: "folder") { moving = true }
                .disabled(isUpdatingTransferControls || folders.isEmpty)
            Button("删除手机副本", systemImage: "trash", role: .destructive) { deleting = true }
                .disabled(isUpdatingTransferControls)
        } label: {
            if isSending { ProgressView().controlSize(.small) }
            else { Text("操作") }
        }
        .disabled(tracks.isEmpty || isImporting || isSending)
        .accessibilityLabel("操作所选 \(tracks.count) 首歌曲")
        .confirmationDialog("移动所选歌曲", isPresented: $moving, titleVisibility: .visible) {
            ForEach(folders) { folder in
                Button(folder.name) { finish(library.moveTracks(tracks, to: folder)) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除所选 \(tracks.count) 首歌曲？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除手机副本", role: .destructive) { finish(library.deleteTracks(tracks)) }
            Button("取消", role: .cancel) {}
        } message: { Text("手表上的歌曲会保留。") }
    }

    private func finish(_ removedURLs: [URL]) {
        removedURLs.forEach { player?.removeFromQueue($0) }
        let removed = Set(removedURLs)
        processed(Set(tracks.filter { removed.contains($0.url) }.map(\.id)))
    }
}

private struct MusicTrackRow: View {
    let track: PhoneTrack
    let queue: [PhoneTrack]
    let library: PhoneLibrary
    let folders: [PhoneFolder]
    let isImporting: Bool
    let isUpdatingTransferControls: Bool
    let isTransferred: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let openPlayer: () -> Void
    let toggleSelection: () -> Void
    let beginSelection: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TrackPlaybackButton(track: track, queue: queue, isSelecting: isSelecting, isSelected: isSelected,
                                openPlayer: openPlayer, toggleSelection: toggleSelection, beginSelection: beginSelection)
            if !isSelecting {
                if isTransferred {
                    Image(systemName: "applewatch").font(.caption).foregroundStyle(.green)
                        .accessibilityLabel("已保存到手表")
                }
                TrackActionsMenu(track: track, library: library, folders: folders,
                                 isImporting: isImporting, isUpdatingTransferControls: isUpdatingTransferControls)
            }
        }
    }
}

private struct TrackPlaybackButton: View {
    @EnvironmentObject private var player: MusicPlayer
    let track: PhoneTrack
    let queue: [PhoneTrack]
    let isSelecting: Bool
    let isSelected: Bool
    let openPlayer: () -> Void
    let toggleSelection: () -> Void
    let beginSelection: () -> Void
    private var isCurrent: Bool { player.currentURL == track.url }

    var body: some View {
        Button {
            if isSelecting { toggleSelection() }
            else if isCurrent { openPlayer() }
            else { player.play(track.url, in: queue.map(\.url)); openPlayer() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelecting ? (isSelected ? "checkmark.circle.fill" : "circle") : (isCurrent ? "waveform" : "music.note"))
                    .font(.title3)
                    .foregroundStyle((isSelecting ? isSelected : isCurrent) ? AppPalette.accent : AppPalette.textSecondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.subheadline.weight(.medium))
                        .foregroundStyle(isCurrent ? AppPalette.accent : AppPalette.textPrimary).lineLimit(2)
                    Text("\(track.formatName) · \(track.duration > 0 ? phoneTime(track.duration) + " · " : "")\(track.formattedSize)")
                        .font(.caption2).foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in beginSelection() })
        .accessibilityAction(named: "选择歌曲", beginSelection)
        .accessibilityValue(isSelecting ? (isSelected ? "已选择" : "未选择") : (isCurrent ? "当前歌曲" : ""))
    }
}

private struct TrackActionsMenu: View {
    @Environment(\.phonePlayer) private var player
    let track: PhoneTrack
    let library: PhoneLibrary
    let folders: [PhoneFolder]
    let isImporting: Bool
    let isUpdatingTransferControls: Bool
    @State private var renaming = false
    @State private var name = ""
    @State private var moving = false
    @State private var deleting = false

    var body: some View {
        Menu {
            Button("发送到手表", systemImage: "applewatch.and.arrow.forward") {
                library.send([track], retryPending: true)
            }.disabled(isImporting)
            Button("重命名", systemImage: "pencil") { name = track.title; renaming = true }
                .disabled(isImporting || isUpdatingTransferControls)
            Button("移动到目录", systemImage: "folder") { moving = true }
                .disabled(isImporting || isUpdatingTransferControls || folders.allSatisfy { $0.name == track.folder })
            Button("删除手机副本", systemImage: "trash", role: .destructive) { deleting = true }
                .disabled(isImporting || isUpdatingTransferControls)
        } label: {
            Image(systemName: "ellipsis").font(.headline).foregroundStyle(AppPalette.textSecondary)
                .frame(width: 44, height: 48).contentShape(Rectangle())
        }
        .accessibilityLabel("歌曲操作：\(track.title)")
        .alert("重命名歌曲", isPresented: $renaming) {
            TextField("歌曲名称", text: $name)
            Button("保存") {
                if library.renameTrack(track, to: name) { cleanPlayerQueue() }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("移动到目录", isPresented: $moving, titleVisibility: .visible) {
            ForEach(folders.filter { $0.name != track.folder }) { folder in
                Button(folder.name) { if library.moveTrack(track, to: folder) { cleanPlayerQueue() } }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除“\(track.title)”？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除手机副本", role: .destructive) {
                if library.deleteTrack(track) { player?.removeFromQueue(track.url) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("手表上的歌曲会保留。") }
    }

    private func cleanPlayerQueue() {
        if !FileManager.default.fileExists(atPath: track.url.path) { player?.removeFromQueue(track.url) }
    }
}

/// A scrollable tail, not an inset or a permanent gap in the list layout.
private struct PinnedPlayerListSpace: View {
    let height: CGFloat

    var body: some View {
        // Keep the transparent tail out of the music section so its last
        // visible row retains the system's rounded bottom corners.
        Section {
            Color.clear.frame(height: height)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                .listRowBackground(Color.clear).accessibilityHidden(true)
        }
    }
}
