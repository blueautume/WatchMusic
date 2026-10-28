import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false
    @State private var tab = 0
    @State private var visibleTransferSummary: String?
    @State private var transferSummaryToken = UUID()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                LibraryHome(openPlayer: { showingPlayer = true })
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }.tabItem { Label("音乐库", systemImage: "music.note.list") }.tag(0)
            NavigationStack {
                TransfersView().safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }.tabItem { Label("传输", systemImage: "applewatch.and.arrow.forward") }
                .badge(library.pendingCount).tag(1)
        }
        .toolbarBackground(AppPalette.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onReceive(library.$transferSummary) { summary in
            visibleTransferSummary = summary
            transferSummaryToken = UUID()
        }
        .task(id: transferSummaryToken) {
            guard visibleTransferSummary != nil else { return }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) }
            catch { return }
            visibleTransferSummary = nil
        }
        .sheet(isPresented: $showingPlayer) { PhoneNowPlayingView().presentationDragIndicator(.visible) }
        .alert("提示", isPresented: Binding(get: { !showingPlayer && (library.errorMessage != nil || player.errorMessage != nil) }, set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(library.errorMessage ?? player.errorMessage ?? "") }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                library.sceneDidBecomeActive(); library.refreshConnection(); library.refreshFolders()
                #if DEBUG
                library.startLANProbeIfRequested()
                #endif
            } else if phase == .background { library.sceneDidEnterBackground() }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-preview-lan") {
                tab = 1
            }
            #if targetEnvironment(simulator)
            library.prepareTransferListPreviewIfRequested()
            if ProcessInfo.processInfo.arguments.contains("-preview-transfers-in-progress") ||
                ProcessInfo.processInfo.arguments.contains("-preview-transfers-completed") { tab = 1 }
            #endif
            if ProcessInfo.processInfo.arguments.contains("-preview-player"), let track = library.allTracks.first {
                player.prepareLayoutPreview(track.url)
                showingPlayer = true
            }
        }
        #endif
    }

    @ViewBuilder private var miniPlayer: some View {
        VStack(spacing: 0) {
            if let summary = visibleTransferSummary {
                Text(summary).font(.caption).foregroundStyle(AppPalette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 8)
            }
            RemotePlaybackControlsView()
            localMiniPlayer
        }.background(AppPalette.background)
    }

    @ViewBuilder private var localMiniPlayer: some View {
        if player.currentURL != nil {
            HStack(spacing: 8) {
                Button { showingPlayer = true } label: {
                    HStack(spacing: 12) {
                        MusicArtwork(title: player.title, data: player.artworkData)
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
                            if !player.artist.isEmpty { Text(player.artist).font(.caption).foregroundStyle(AppPalette.textSecondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("打开播放器：\(player.title)")
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Button(action: player.next) {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("下一首")
            }
            .padding(12).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16).padding(.bottom, 8).background(AppPalette.background)
        }
    }
}

private struct LibraryHome: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    let openPlayer: () -> Void
    @State private var search = ""
    @State private var importing = false
    @State private var showCreate = false
    @State private var folderName = ""
    @State private var editingFolder: PhoneFolder?
    @State private var deletingFolder: PhoneFolder?
    @State private var importDestination: PhoneFolder?
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    private var results: [PhoneTrack] {
        library.allTracks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.folder.localizedCaseInsensitiveContains(search) }
    }

    private var importLabel: some View {
        Label("导入音乐", systemImage: "plus.circle.fill")
            .font(.headline).foregroundStyle(AppPalette.accent).frame(minHeight: 40)
    }
    private var selectedTracks: [PhoneTrack] { results.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        List {
            if search.isEmpty && !isSelecting {
                Section {
                    if library.folders.count == 1, let folder = library.folders.first {
                        Button { importDestination = folder; importing = true } label: { importLabel }
                            .disabled(library.isImporting)
                    } else {
                        Menu {
                            ForEach(library.folders) { folder in
                                Button(folder.name) { importDestination = folder; importing = true }
                            }
                        } label: { importLabel }.disabled(library.isImporting)
                    }
                    if library.isImporting {
                        ProgressView(library.importMessage, value: library.importProgress).font(.caption).tint(AppPalette.accent)
                    } else if let summary = library.importSummary {
                        Text(summary).font(.caption).foregroundStyle(AppPalette.textSecondary)
                    }
                }.listRowBackground(AppPalette.surface)
                Section {
                    ForEach(library.folders) { folder in
                        NavigationLink {
                            FolderDetailView(folder: folder, openPlayer: openPlayer)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "folder.fill").font(.title3).foregroundStyle(AppPalette.accent)
                                Text(folder.name).font(.body.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text("\(library.tracks(in: folder).count)").font(.subheadline.monospacedDigit()).foregroundStyle(AppPalette.textSecondary)
                            }.frame(minHeight: 36)
                        }
                        .contextMenu {
                            Button("发送到手表", systemImage: "applewatch.and.arrow.forward") { library.send(library.tracks(in: folder)) }
                                .disabled(library.isImporting || library.tracks(in: folder).isEmpty)
                            Button("重命名", systemImage: "pencil") { folderName = folder.name; editingFolder = folder }
                            Button("删除目录", systemImage: "trash", role: .destructive) { deletingFolder = folder }
                        }
                    }
                } header: { Text("目录") }.listRowBackground(AppPalette.surface)
            }
            Section {
                if results.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "还没有音乐" : "没有找到歌曲", systemImage: "music.note")
                        .listRowBackground(Color.clear)
                }
                ForEach(results) { track in
                    MusicTrackRow(track: track, queue: results, openPlayer: openPlayer,
                                  isSelecting: isSelecting, isSelected: selectedIDs.contains(track.id)) {
                        if !selectedIDs.insert(track.id).inserted { selectedIDs.remove(track.id) }
                    }
                }
            } header: {
                HStack { Text(search.isEmpty ? "全部歌曲" : "搜索结果"); Spacer(); Text("\(results.count) 首") }
            }.listRowBackground(AppPalette.surface)
        }
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle("音乐库")
        .searchable(text: $search, prompt: "搜索歌曲或目录")
        .onChange(of: results.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                TrackBatchActions(tracks: selectedTracks) { processed in
                    selectedIDs.subtract(processed)
                    if selectedIDs.isEmpty { isSelecting = false }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button(selectedIDs.count == results.count ? "取消全选" : "全选") {
                        selectedIDs = selectedIDs.count == results.count ? [] : Set(results.map(\.id))
                    }.disabled(results.isEmpty).frame(minHeight: 44)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(isSelecting ? "完成" : "多选") {
                    isSelecting.toggle(); selectedIDs.removeAll()
                }.disabled(results.isEmpty && !isSelecting).frame(minHeight: 44)
                if !isSelecting {
                    Button { folderName = ""; showCreate = true } label: {
                        Image(systemName: "folder.badge.plus").frame(width: 44, height: 44)
                    }.disabled(library.isImporting).accessibilityLabel("新建目录")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AudioFileFormat.importContentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): if let folder = importDestination ?? library.folders.first { library.importFiles(urls, into: folder) }
            case .failure(let error): library.errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .alert("新建目录", isPresented: $showCreate) {
            TextField("目录名称", text: $folderName)
            Button("创建") { _ = library.createFolder(folderName) }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名目录", isPresented: Binding(get: { editingFolder != nil }, set: { if !$0 { editingFolder = nil } })) {
            TextField("目录名称", text: $folderName)
            Button("保存") {
                if let folder = editingFolder {
                    let tracks = library.tracks(in: folder)
                    if library.renameFolder(folder, to: folderName) { tracks.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.forEach { player.removeFromQueue($0.url) } }
                }
                editingFolder = nil
            }
            Button("取消", role: .cancel) { editingFolder = nil }
        }
        .confirmationDialog("删除“\(deletingFolder?.name ?? "")”？", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), titleVisibility: .visible) {
            Button("删除手机中的目录和歌曲", role: .destructive) {
                if let folder = deletingFolder {
                    let tracks = library.tracks(in: folder)
                    if library.deleteFolder(folder) { tracks.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.forEach { player.removeFromQueue($0.url) } }
                }
                deletingFolder = nil
            }
            Button("取消", role: .cancel) { deletingFolder = nil }
        } message: { Text("手表上的歌曲会保留。") }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-preview-music-selection") {
                isSelecting = true
                selectedIDs = Set(results.prefix(2).map(\.id))
            }
        }
        #endif
    }
}

private struct FolderDetailView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    let folder: PhoneFolder
    let openPlayer: () -> Void
    @State private var importing = false
    @State private var search = ""
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    private var tracks: [PhoneTrack] {
        library.tracks(in: folder).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if !tracks.isEmpty && !isSelecting {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            if let first = tracks.first { player.play(first.url, in: tracks.map(\.url)); openPlayer() }
                        } label: {
                            Label("播放全部", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.plain).foregroundStyle(.black).background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 14))
                        Button { library.send(tracks) } label: {
                            Image(systemName: "applewatch.and.arrow.forward").font(.title3).frame(width: 56, height: 48)
                        }.buttonStyle(.plain).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                            .disabled(library.isImporting)
                            .accessibilityLabel("发送这些歌曲到手表")
                    }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            Section {
                if tracks.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "还没有音乐" : "没有找到歌曲", systemImage: "music.note")
                        .listRowBackground(Color.clear)
                }
                ForEach(tracks) { track in
                    MusicTrackRow(track: track, queue: tracks, openPlayer: openPlayer,
                                  isSelecting: isSelecting, isSelected: selectedIDs.contains(track.id)) {
                        if !selectedIDs.insert(track.id).inserted { selectedIDs.remove(track.id) }
                    }
                }
            } header: { Text("\(tracks.count) 首") }.listRowBackground(AppPalette.surface)
            if library.isImporting {
                ProgressView(library.importMessage, value: library.importProgress).font(.caption).tint(AppPalette.accent)
                    .listRowBackground(AppPalette.surface)
            }
        }
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle(folder.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索此目录")
        .onChange(of: tracks.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                TrackBatchActions(tracks: tracks.filter { selectedIDs.contains($0.id) }) { processed in
                    selectedIDs.subtract(processed)
                    if selectedIDs.isEmpty { isSelecting = false }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button(selectedIDs.count == tracks.count ? "取消全选" : "全选") {
                        selectedIDs = selectedIDs.count == tracks.count ? [] : Set(tracks.map(\.id))
                    }.disabled(tracks.isEmpty).frame(minHeight: 44)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(isSelecting ? "完成" : "多选") {
                    isSelecting.toggle(); selectedIDs.removeAll()
                }.disabled(tracks.isEmpty && !isSelecting).frame(minHeight: 44)
                if !isSelecting {
                    Button { importing = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
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
                isSelecting = true
                selectedIDs = Set(tracks.prefix(2).map(\.id))
            }
        }
        #endif
    }
}

private struct TrackBatchActions: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    let tracks: [PhoneTrack]
    let processed: (Set<String>) -> Void
    @State private var moving = false
    @State private var deleting = false
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 8) {
            Text("已选 \(tracks.count) 首").font(.caption).foregroundStyle(AppPalette.textSecondary)
            HStack(spacing: 12) {
                Button {
                    isSending = true
                    library.send(tracks, retryPending: true) { ids in isSending = false; processed(ids) }
                } label: {
                    HStack {
                        if isSending { ProgressView().controlSize(.small) }
                        else { Label("发送", systemImage: "applewatch.and.arrow.forward") }
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                Button { moving = true } label: { Label("移动", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(library.isUpdatingTransferControls)
                Button(role: .destructive) { deleting = true } label: { Label("删除", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44) }
                    .tint(.red).disabled(library.isUpdatingTransferControls)
            }.font(.subheadline).buttonStyle(.bordered)
                .disabled(tracks.isEmpty || library.isImporting || isSending)
        }.padding(.horizontal, 20).padding(.vertical, 10).background(AppPalette.surface)
        .confirmationDialog("移动所选歌曲", isPresented: $moving, titleVisibility: .visible) {
            ForEach(library.folders) { folder in
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
        removedURLs.forEach { player.removeFromQueue($0) }
        let removed = Set(removedURLs)
        processed(Set(tracks.filter { removed.contains($0.url) }.map(\.id)))
    }
}

private struct MusicTrackRow: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    let track: PhoneTrack
    let queue: [PhoneTrack]
    let openPlayer: () -> Void
    var isSelecting = false
    var isSelected = false
    var toggleSelection: () -> Void = {}
    @State private var renaming = false
    @State private var name = ""
    @State private var moving = false
    @State private var deleting = false
    private var isCurrent: Bool { player.currentURL == track.url }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isSelecting { toggleSelection() }
                else if isCurrent { openPlayer() }
                else { player.play(track.url, in: queue.map(\.url)); openPlayer() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelecting ? (isSelected ? "checkmark.circle.fill" : "circle") : (isCurrent ? "waveform" : "music.note"))
                        .font(.title3).foregroundStyle((isSelecting ? isSelected : isCurrent) ? AppPalette.accent : AppPalette.textSecondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.subheadline.weight(.medium)).foregroundStyle(isCurrent ? AppPalette.accent : .white).lineLimit(2)
                        Text("\(track.formatName) · \(track.duration > 0 ? phoneTime(track.duration) + " · " : "")\(track.formattedSize)")
                            .font(.caption2).foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !isSelecting && library.isFullyTransferred(track) {
                Image(systemName: "applewatch").font(.caption).foregroundStyle(.green).accessibilityLabel("已保存到手表")
            }
            if !isSelecting { Menu {
                Button("发送到手表", systemImage: "applewatch.and.arrow.forward") { library.send([track], retryPending: true) }
                    .disabled(library.isImporting)
                Button("重命名", systemImage: "pencil") { name = track.title; renaming = true }
                Button("移动到目录", systemImage: "folder") { moving = true }
                Button("删除手机副本", systemImage: "trash", role: .destructive) { deleting = true }
            } label: {
                Image(systemName: "ellipsis").font(.headline).foregroundStyle(AppPalette.textSecondary)
                    .frame(width: 44, height: 48).contentShape(Rectangle())
            }.accessibilityLabel("歌曲操作：\(track.title)") }
        }
        .alert("重命名歌曲", isPresented: $renaming) {
            TextField("歌曲名称", text: $name)
            Button("保存") { if library.renameTrack(track, to: name), !FileManager.default.fileExists(atPath: track.url.path) { player.removeFromQueue(track.url) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("移动到目录", isPresented: $moving, titleVisibility: .visible) {
            ForEach(library.folders.filter { $0.name != track.folder }) { folder in
                Button(folder.name) { if library.moveTrack(track, to: folder), !FileManager.default.fileExists(atPath: track.url.path) { player.removeFromQueue(track.url) } }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除“\(track.title)”？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除手机副本", role: .destructive) { if library.deleteTrack(track) { player.removeFromQueue(track.url) } }
            Button("取消", role: .cancel) {}
        } message: { Text("手表上的歌曲会保留。") }
    }
}

private enum TransferListTab: String, CaseIterable, Identifiable {
    case inProgress = "进行中", stored = "已传输"
    var id: String { rawValue }
}

private enum TransferClearAction {
    case selected(Set<String>), allTasks, allStored
}

private struct TransfersView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @State private var clearing = false
    @State private var clearAction = TransferClearAction.allTasks
    @State private var selectedTab = TransferListTab.inProgress
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    private var records: [TransferRecord] {
        selectedTab == .inProgress ? library.activeTransfers : library.storedTransfers
    }
    private var controlIDs: Set<String>? { isSelecting ? selectedIDs : nil }
    private var shouldStart: Bool { library.shouldStartTransfers(ids: controlIDs) }
    private var clearTitle: String {
        switch clearAction {
        case .selected(let ids): return "清除所选 \(ids.count) 项？"
        case .allTasks: return "清除全部任务？"
        case .allStored: return "清除全部已传输记录？"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("传输记录", selection: $selectedTab) {
                ForEach(TransferListTab.allCases) { tab in
                    let count = tab == .inProgress ? library.activeTransfers.count : library.storedTransfers.count
                    Text("\(tab.rawValue) · \(count)").tag(tab)
                }
            }.pickerStyle(.segmented)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
            ScrollView {
                if records.isEmpty {
                    ContentUnavailableView(selectedTab == .inProgress ? "没有进行中的传输" : "还没有已传输的歌曲",
                                           systemImage: selectedTab == .inProgress ? "arrow.up.doc" : "checkmark.circle")
                        .padding(.top, 48)
                    if selectedTab == .inProgress && !library.canSend {
                        Label(library.connectionDescription, systemImage: "applewatch")
                            .font(.caption).foregroundStyle(AppPalette.textSecondary).padding(.horizontal, 20)
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(records) { record in
                            TransferRow(record: record, isSelecting: isSelecting, isSelected: selectedIDs.contains(record.id)) {
                                if !selectedIDs.insert(record.id).inserted { selectedIDs.remove(record.id) }
                            }
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            }.id(selectedTab)
        }
        .background(AppPalette.background).navigationTitle("传输")
        .onChange(of: selectedTab) { _, _ in selectedIDs.removeAll() }
        .onChange(of: records.map(\.id)) { _, ids in
            selectedIDs.formIntersection(ids)
            if ids.isEmpty { isSelecting = false }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                HStack {
                    Text("已选 \(selectedIDs.count) 项").font(.subheadline)
                    Spacer()
                    Button(selectedIDs.count == records.count ? "取消全选" : "全选") {
                        selectedIDs = selectedIDs.count == records.count ? [] : Set(records.map(\.id))
                    }.frame(minHeight: 44).disabled(records.isEmpty)
                }.padding(.horizontal, 20).padding(.vertical, 8).background(AppPalette.surface)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selectedTab == .inProgress {
                    Button { library.toggleTransfers(ids: controlIDs) } label: {
                        if library.isUpdatingTransferControls { ProgressView().controlSize(.small) }
                        else { Label(shouldStart ? "开始" : "暂停", systemImage: shouldStart ? "play.fill" : "pause.fill") }
                    }.frame(minHeight: 44).disabled(!library.canToggleTransfers(ids: controlIDs))
                        .accessibilityLabel((shouldStart ? "开始" : "暂停") + (isSelecting ? "所选任务" : "全部任务"))
                }
                Button(isSelecting ? "完成" : "多选") { isSelecting.toggle(); selectedIDs.removeAll() }
                    .frame(minHeight: 44).disabled(records.isEmpty && !isSelecting)
                Menu {
                    if isSelecting {
                        Button(selectedIDs.count == records.count ? "取消全选" : "全选") {
                            selectedIDs = selectedIDs.count == records.count ? [] : Set(records.map(\.id))
                        }
                        Button("清除所选", systemImage: "trash", role: .destructive) {
                            clearAction = .selected(selectedIDs); clearing = true
                        }.disabled(selectedIDs.isEmpty)
                    }
                    if selectedTab == .inProgress {
                        Button("清除全部任务", systemImage: "trash", role: .destructive) {
                            clearAction = .allTasks; clearing = true
                        }.disabled(!library.transfers.contains { $0.state != .stored })
                    } else {
                        Button("清除全部已传输记录", systemImage: "trash", role: .destructive) {
                            clearAction = .allStored; clearing = true
                        }.disabled(records.isEmpty)
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("更多任务操作")
            }
        }
        .confirmationDialog(clearTitle, isPresented: $clearing, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                switch clearAction {
                case .selected(let ids): library.clearTransfers(ids: ids)
                case .allTasks: library.clearAllTasks()
                case .allStored: library.clearCompletedTransfers()
                }
                selectedIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: { Text("被清除的未完成任务会停止，已保存的音乐会保留。") }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-preview-transfers-completed") { selectedTab = .stored }
            if ProcessInfo.processInfo.arguments.contains("-preview-transfer-selection") {
                isSelecting = true
                selectedIDs = Set(records.filter { $0.state == .queued || $0.state == .paused }.prefix(2).map(\.id))
            }
        }
        #endif
    }
}

private struct TransferRow: View {
    @EnvironmentObject private var library: PhoneLibrary
    let record: TransferRecord
    var isSelecting = false
    var isSelected = false
    var toggleSelection: () -> Void = {}
    private var metrics: TransferMetrics? { library.transferMetrics[record.id] }
    private var fraction: Double { min(1, max(0, library.progress[record.id] ?? 0)) }
    private var hasStarted: Bool { (metrics?.completedBytes ?? 0) > 0 || metrics?.isTransferring == true || fraction > 0 }
    private var tint: Color {
        switch record.state {
        case .stored: return .green
        case .failed: return .red
        case .cancelled, .paused: return AppPalette.textSecondary
        case .queued: return hasStarted ? AppPalette.accent : AppPalette.textSecondary
        case .awaitingReceipt, .outdated: return AppPalette.accent
        }
    }
    private var status: String {
        if record.state == .awaitingReceipt {
            return record.method == .localNetwork ? "正在校验和保存" : "等待手表确认"
        }
        guard record.state == .queued else { return record.state.title }
        if record.method == .localNetwork && library.isCurrentLANTransfer(record.id) && library.isPreparingLAN && record.lanSessionID == nil { return "正在准备…" }
        if fraction >= 1 { return "等待手表确认" }
        if metrics?.isTransferring == true { return "传输中" }
        if hasStarted { return "等待进度更新" }
        if record.method == .localNetwork && library.isCurrentLANTransfer(record.id) && library.isAwaitingLANAcceptance { return "等待手表接收" }
        return "等待传输"
    }

    var body: some View {
        if isSelecting {
            Button(action: toggleSelection) { card }.buttonStyle(.plain)
                .accessibilityValue(isSelected ? "已选择" : "未选择")
        } else { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.state.symbol).font(.title2).foregroundStyle(tint).frame(width: 26, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.songTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(status).font(.caption).foregroundStyle(tint)
                    if record.state == .failed && !record.message.isEmpty && record.message != record.state.title {
                        Text(record.message).font(.caption2).foregroundStyle(AppPalette.textSecondary)
                    }
                    if record.state == .stored && record.totalBytes > 0 {
                        Text(transferBytes(record.totalBytes)).font(.caption2).foregroundStyle(AppPalette.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.textSecondary).frame(width: 44, height: 44)
                } else if record.state == .queued || record.state == .paused || (record.method == .localNetwork && record.state == .awaitingReceipt) {
                    Button { library.cancel(record) } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).accessibilityLabel("取消传输 \(record.songTitle)")
                } else if record.state != .stored && !record.state.isPending {
                    Button("重试") { library.retry(record) }.font(.caption.weight(.semibold))
                        .buttonStyle(.bordered).tint(AppPalette.accent).frame(minHeight: 44)
                }
            }
            if (record.state == .queued || record.state == .paused) && hasStarted {
                ProgressView(value: fraction).tint(AppPalette.accent)
                    .accessibilityLabel("传输进度").accessibilityValue("\(Int(fraction * 100))%")
                HStack {
                    if let metrics, metrics.totalBytes > 0 {
                        Text("\(transferBytes(metrics.completedBytes)) / \(transferBytes(metrics.totalBytes))")
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(fraction * 100))%")
                }.font(.caption2.monospacedDigit()).foregroundStyle(AppPalette.textSecondary)
                if let metrics, metrics.isTransferring {
                    HStack {
                        if let speed = metrics.bytesPerSecond, speed.isFinite, speed > 0 {
                            Text("约 \(transferBytes(Int64(min(speed, 1_000_000_000_000))))/秒")
                        } else { Text("正在估算速度…") }
                        Spacer(minLength: 8)
                        if let eta = metrics.estimatedTimeRemaining, eta.isFinite, eta > 0 {
                            Text("剩余约 \(transferDuration(eta))")
                        }
                    }.font(.caption2.monospacedDigit()).foregroundStyle(AppPalette.textSecondary)
                }
            }
        }.padding(16).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

private func transferBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

private func transferDuration(_ seconds: TimeInterval) -> String {
    let value = Int(min(ceil(seconds), 359_999))
    if value < 60 { return "\(max(1, value)) 秒" }
    if value < 3_600 { return "\(value / 60) 分 \(value % 60) 秒" }
    return "\(value / 3_600) 小时 \((value % 3_600) / 60) 分"
}

func phoneTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3_600, (value % 3_600) / 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}
