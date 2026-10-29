import SwiftUI

private enum TransferListTab: String, CaseIterable, Identifiable {
    case inProgress = "进行中", stored = "已传输"
    var id: String { rawValue }
}

struct TransfersView: View {
    @EnvironmentObject private var library: PhoneLibrary
    @State private var selectedTab = TransferListTab.inProgress
    @State private var clearingTasks = false

    private var records: [TransferRecord] {
        selectedTab == .inProgress ? library.activeTransfers : library.storedTransfers
    }

    var body: some View {
        VStack(spacing: 0) {
            TransferHeading(progress: library.transferProgress, showsEstimate: selectedTab == .inProgress)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 18)
            Picker("传输记录", selection: $selectedTab) {
                ForEach(TransferListTab.allCases) { tab in
                    let count = tab == .inProgress ? library.activeTransfers.count : library.storedTransfers.count
                    Text("\(tab.rawValue) · \(count)").tag(tab)
                }
            }
            .pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)

            if selectedTab == .inProgress && !records.isEmpty {
                queueControl.padding(.horizontal, 20).padding(.bottom, 12)
            }
            ScrollView {
                if records.isEmpty {
                    ContentUnavailableView(
                        selectedTab == .inProgress ? "没有进行中的传输" : "还没有已传输的记录",
                        systemImage: selectedTab == .inProgress ? "arrow.up.doc" : "checkmark.circle"
                    ).padding(.top, 36)
                    if selectedTab == .inProgress && !library.canSend {
                        Label(library.connectionDescription, systemImage: "applewatch")
                            .font(.caption).foregroundStyle(AppPalette.textSecondary).padding(.horizontal, 20)
                    }
                } else {
                    TransferRecordCards(library: library, records: records, progress: library.transferProgress,
                                        inProgress: selectedTab == .inProgress,
                                        isPreparing: library.isPreparingLAN,
                                        isAwaitingAcceptance: library.isAwaitingLANAcceptance,
                                        controlsBusy: library.isUpdatingTransferControls)
                }
            }.id(selectedTab)
        }
        .foregroundStyle(AppPalette.textPrimary)
        .background(AppPalette.background)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if selectedTab == .inProgress { clearingTasks = true }
                    else { library.clearCompletedTransfers() }
                } label: { Image(systemName: "paintbrush") }
                .disabled(records.isEmpty || library.isUpdatingTransferControls)
                .accessibilityLabel(selectedTab == .inProgress ? "清除全部任务" : "清空已传输记录")
            }
        }
        .confirmationDialog("清除全部任务？", isPresented: $clearingTasks, titleVisibility: .visible) {
            Button("清除全部任务", role: .destructive) { library.clearAllTasks() }
            Button("取消", role: .cancel) {}
        } message: { Text("未完成的传输会停止，手表上的音乐会保留。") }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-preview-transfers-completed") { selectedTab = .stored }
        }
        #endif
    }

    private var queueControl: some View {
        HStack {
            Text("\(records.count) 项任务").font(.subheadline).foregroundStyle(AppPalette.textSecondary)
            Spacer()
            Button { library.toggleTransfers() } label: {
                HStack(spacing: 6) {
                    if library.isUpdatingTransferControls { ProgressView().controlSize(.small) }
                    else { Image(systemName: library.shouldStartTransfers() ? "play.fill" : "pause.fill") }
                    Text(library.shouldStartTransfers() ? "全部开始" : "全部暂停")
                }.font(.subheadline.weight(.medium)).frame(minHeight: 36)
            }
            .disabled(!library.canToggleTransfers())
            .buttonStyle(.bordered).tint(AppPalette.accent)
        }
    }
}

/// Sorting observes only transient measurements, so the active song can move to
/// the front without publishing an unrelated library/navigation update.
private struct TransferRecordCards: View {
    @Environment(\.pinnedPlayerClearance) private var playerClearance
    let library: PhoneLibrary
    let records: [TransferRecord]
    @ObservedObject var progress: PhoneTransferProgress
    let inProgress: Bool
    let isPreparing: Bool
    let isAwaitingAcceptance: Bool
    let controlsBusy: Bool

    private var ordered: [TransferRecord] {
        inProgress ? TransferListOrdering.activeTransfers(records, metrics: progress.metrics) : records
    }

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(ordered) { record in
                TransferRow(record: record, library: library, progress: progress,
                            isCurrent: library.isCurrentLANTransfer(record.id),
                            isPreparing: isPreparing, isAwaitingAcceptance: isAwaitingAcceptance,
                            controlsBusy: controlsBusy,
                            canToggle: library.canToggleTransfers(ids: [record.id]),
                            shouldStart: library.shouldStartTransfers(ids: [record.id]))
            }
        }.padding(.horizontal, 20).padding(.bottom, 24 + playerClearance)
    }
}

private struct TransferHeading: View {
    @ObservedObject var progress: PhoneTransferProgress
    let showsEstimate: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("传输").font(.largeTitle.bold()).foregroundStyle(AppPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if showsEstimate, let estimate = progress.remainingEstimate {
                Text(estimate).font(.subheadline).foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                    .accessibilityLabel("全部任务\(estimate)")
            }
        }
    }
}

private struct TransferRow: View {
    let record: TransferRecord
    let library: PhoneLibrary
    @ObservedObject var progress: PhoneTransferProgress
    let isCurrent: Bool
    let isPreparing: Bool
    let isAwaitingAcceptance: Bool
    let controlsBusy: Bool
    let canToggle: Bool
    let shouldStart: Bool

    private var metrics: TransferMetrics? { progress.metrics[record.id] }
    private var fraction: Double { min(1, max(0, progress.values[record.id] ?? 0)) }
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
        if isCurrent && isPreparing && record.lanSessionID == nil { return "正在准备…" }
        if fraction >= 1 { return "等待手表确认" }
        if metrics?.isTransferring == true { return "传输中" }
        if hasStarted { return "等待继续传输" }
        if isCurrent && isAwaitingAcceptance { return "等待手表接收" }
        return "等待传输"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.state.symbol).font(.title2).foregroundStyle(tint)
                    .frame(width: 26, height: 44).accessibilityHidden(true)
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
                controls
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
        }
        .padding(16).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var controls: some View {
        if record.state == .queued || record.state == .paused || (record.method == .localNetwork && record.state == .awaitingReceipt) {
            HStack(spacing: 0) {
                if canToggle {
                    Button { library.toggleTransfers(ids: [record.id]) } label: {
                        Image(systemName: shouldStart ? "play.circle" : "pause.circle")
                            .font(.title3).frame(width: 40, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(AppPalette.accent).disabled(controlsBusy)
                    .accessibilityLabel("\(shouldStart ? "继续" : "暂停")传输 \(record.songTitle)")
                }
                Button { library.cancel(record) } label: {
                    Image(systemName: "xmark.circle").font(.title3).frame(width: 40, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).disabled(controlsBusy)
                .accessibilityLabel("取消传输 \(record.songTitle)")
            }
        } else if record.state != .stored && !record.state.isPending {
            Button("重试") { library.retry(record) }
                .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(AppPalette.accent)
                .frame(minHeight: 44).disabled(controlsBusy)
        }
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
