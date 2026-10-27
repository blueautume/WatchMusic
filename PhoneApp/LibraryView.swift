import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false
    @State private var tab = 0

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
                library.transferMethod = .localNetwork
            }
            if ProcessInfo.processInfo.arguments.contains("-preview-player"), let track = library.allTracks.first {
                player.prepareLayoutPreview(track.url)
                showingPlayer = true
            }
        }
        #endif
    }

    @ViewBuilder private var miniPlayer: some View {
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
    private var results: [PhoneTrack] {
        library.allTracks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.folder.localizedCaseInsensitiveContains(search) }
    }

    private var importLabel: some View {
        Label("导入音乐", systemImage: "plus.circle.fill")
            .font(.headline).foregroundStyle(AppPalette.accent).frame(minHeight: 40)
    }

    var body: some View {
        List {
            if search.isEmpty {
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
                ForEach(results) { track in MusicTrackRow(track: track, queue: results, openPlayer: openPlayer) }
            } header: {
                HStack { Text(search.isEmpty ? "全部歌曲" : "搜索结果"); Spacer(); Text("\(results.count) 首") }
            }.listRowBackground(AppPalette.surface)
        }
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle("音乐库")
        .searchable(text: $search, prompt: "搜索歌曲或目录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { folderName = ""; showCreate = true } label: {
                    Image(systemName: "folder.badge.plus").frame(width: 44, height: 44)
                }.disabled(library.isImporting).accessibilityLabel("新建目录")
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
    }
}

private struct FolderDetailView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    let folder: PhoneFolder
    let openPlayer: () -> Void
    @State private var importing = false
    @State private var search = ""
    private var tracks: [PhoneTrack] {
        library.tracks(in: folder).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if !tracks.isEmpty {
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
                            .accessibilityLabel("发送这些歌曲到手表")
                    }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            Section {
                if tracks.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "还没有音乐" : "没有找到歌曲", systemImage: "music.note")
                        .listRowBackground(Color.clear)
                }
                ForEach(tracks) { MusicTrackRow(track: $0, queue: tracks, openPlayer: openPlayer) }
            } header: { Text("\(tracks.count) 首") }.listRowBackground(AppPalette.surface)
            if library.isImporting {
                ProgressView(library.importMessage, value: library.importProgress).font(.caption).tint(AppPalette.accent)
                    .listRowBackground(AppPalette.surface)
            }
        }
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle(folder.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索此目录")
        .toolbar {
            Button { importing = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .disabled(library.isImporting).accessibilityLabel("导入音乐")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AudioFileFormat.importContentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls, into: folder)
            case .failure(let error): library.errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct MusicTrackRow: View {
    @EnvironmentObject private var library: PhoneLibrary
    @EnvironmentObject private var player: MusicPlayer
    let track: PhoneTrack
    let queue: [PhoneTrack]
    let openPlayer: () -> Void
    @State private var renaming = false
    @State private var name = ""
    @State private var moving = false
    @State private var deleting = false
    private var isCurrent: Bool { player.currentURL == track.url }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isCurrent { openPlayer() }
                else { player.play(track.url, in: queue.map(\.url)); openPlayer() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isCurrent ? "waveform" : "music.note")
                        .font(.title3).foregroundStyle(isCurrent ? AppPalette.accent : AppPalette.textSecondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.subheadline.weight(.medium)).foregroundStyle(isCurrent ? AppPalette.accent : .white).lineLimit(2)
                        Text("\(track.formatName) · \(track.duration > 0 ? phoneTime(track.duration) + " · " : "")\(track.formattedSize)")
                            .font(.caption2).foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if library.isFullyTransferred(track) {
                Image(systemName: "applewatch").font(.caption).foregroundStyle(.green).accessibilityLabel("已保存到手表")
            }
            Menu {
                Button("发送到手表", systemImage: "applewatch.and.arrow.forward") { library.send([track], retryPending: true) }
                Button("重命名", systemImage: "pencil") { name = track.title; renaming = true }
                Button("移动到目录", systemImage: "folder") { moving = true }
                Button("删除手机副本", systemImage: "trash", role: .destructive) { deleting = true }
            } label: {
                Image(systemName: "ellipsis").font(.headline).foregroundStyle(AppPalette.textSecondary)
                    .frame(width: 44, height: 48).contentShape(Rectangle())
            }.accessibilityLabel("歌曲操作：\(track.title)")
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

private struct TransfersView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @State private var clearing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("传输方式", selection: $library.transferMethod) {
                        ForEach(TransferMethod.allCases) { method in Text(method.title).tag(method) }
                    }.pickerStyle(.segmented).disabled(library.isLANActive)
                    if library.transferMethod == .localNetwork {
                        Text("同一 Wi-Fi，保持手机 App 打开").font(.caption).foregroundStyle(AppPalette.textSecondary)
                        if library.isLANActive {
                            HStack(spacing: 10) {
                                if library.isPreparingLAN { ProgressView().tint(AppPalette.accent) }
                                Text(library.lanStatus).font(.caption).foregroundStyle(AppPalette.accent)
                                Spacer(minLength: 4)
                                Button("停止") { library.stopLANTransfers() }
                                    .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(.red).frame(minHeight: 44)
                            }
                        } else if !library.lanStatus.isEmpty {
                            Text(library.lanStatus).font(.caption).foregroundStyle(AppPalette.textSecondary)
                        }
                    }
                }.padding(16).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                Label(library.connectionDescription, systemImage: "applewatch")
                    .font(.subheadline).foregroundStyle(library.canSend ? Color.green : AppPalette.textSecondary)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                if library.transfers.isEmpty {
                    ContentUnavailableView("还没有传输", systemImage: "arrow.up.doc")
                } else {
                    LazyVStack(spacing: 12) { ForEach(library.transfers) { TransferRow(record: $0) } }
                }
            }.padding(20)
        }
        .background(AppPalette.background).navigationTitle("传输")
        .toolbar {
            Button { clearing = true } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("管理传输记录")
        }
        .confirmationDialog("传输记录", isPresented: $clearing) {
            Button("清除已完成记录") { library.clearCompletedTransfers() }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct TransferRow: View {
    @EnvironmentObject private var library: PhoneLibrary
    let record: TransferRecord
    private var metrics: TransferMetrics? { library.transferMetrics[record.id] }
    private var tint: Color { record.state == .stored ? .green : (record.state == .failed ? .red : AppPalette.accent) }
    private var status: String {
        if record.method == .localNetwork {
            if record.state == .awaitingReceipt { return "手表正在校验和保存" }
            if record.state == .queued {
                if library.isPreparingLAN && record.lanSessionID == nil { return "正在准备…" }
                if library.isAwaitingLANAcceptance { return "等待手表接收" }
                return metrics?.isTransferring == true ? "传输中" : "等待手表后台处理"
            }
        }
        guard record.state == .queued else { return record.state.title }
        guard let metrics else { return "等待系统传输" }
        if metrics.totalBytes > 0 && metrics.completedBytes >= metrics.totalBytes { return "等待手表确认" }
        return metrics.isTransferring ? "传输中" : "等待系统传输"
    }
    private var fraction: Double { min(1, max(0, library.progress[record.id] ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.state.symbol).font(.title2).foregroundStyle(tint).frame(width: 26, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.songTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(status).foregroundStyle(tint)
                        Text(record.method.title).foregroundStyle(AppPalette.textSecondary)
                    }.font(.caption)
                    if record.state == .failed { Text(record.message).font(.caption2).foregroundStyle(AppPalette.textSecondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if record.state == .queued || (record.method == .localNetwork && record.state == .awaitingReceipt) {
                    Button { library.cancel(record) } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).accessibilityLabel("取消传输 \(record.songTitle)")
                } else if record.state != .stored {
                    if record.method == .localNetwork {
                        Menu {
                            Button("重试局域网") { library.retry(record) }
                            Button("改用普通传输") { library.retry(record, using: .system) }
                        } label: { Text("重试").font(.caption.weight(.semibold)).frame(minHeight: 44) }
                            .buttonStyle(.bordered).tint(AppPalette.accent)
                    } else {
                        Button("重试") { library.retry(record) }.font(.caption.weight(.semibold))
                            .buttonStyle(.bordered).tint(AppPalette.accent).frame(minHeight: 44)
                    }
                }
            }
            if record.state == .queued {
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
