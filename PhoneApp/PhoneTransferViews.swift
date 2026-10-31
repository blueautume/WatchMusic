import SwiftUI

private enum TransferListTab: String, CaseIterable, Identifiable {
    case inProgress, stored
    var title: String { self == .inProgress ? L10n.text("进行中") : L10n.text("已传输") }
    var id: String { rawValue }
}

struct TransfersView: View {
    @EnvironmentObject private var library: PhoneLibrary
    let openSettings: () -> Void
    @State private var selectedTab = TransferListTab.inProgress
    @State private var clearingTasks = false

    private var records: [TransferRecord] {
        selectedTab == .inProgress ? library.activeTransfers : library.storedTransfers
    }

    var body: some View {
        VStack(spacing: 0) {
            TransferHeading(progress: library.transferProgress, showsEstimate: selectedTab == .inProgress)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 18)
            Picker(L10n.text("传输记录"), selection: $selectedTab) {
                ForEach(TransferListTab.allCases) { tab in
                    let count = tab == .inProgress ? library.activeTransfers.count : library.storedTransfers.count
                    Text("\(tab.title) · \(count)").tag(tab)
                }
            }
            .pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)

            if selectedTab == .inProgress && !records.isEmpty {
                queueControl.padding(.horizontal, 20).padding(.bottom, 12)
            }
            ScrollView {
                if records.isEmpty {
                    ContentUnavailableView(
                        selectedTab == .inProgress ? L10n.text("没有进行中的传输") : L10n.text("还没有已传输的记录"),
                        systemImage: selectedTab == .inProgress ? "arrow.up.doc" : "checkmark.circle"
                    ).padding(.top, 36)
                    if selectedTab == .inProgress && !library.canSend {
                        Label(L10n.message(library.connectionDescription), systemImage: "applewatch")
                            .font(.caption).foregroundStyle(AppPalette.textSecondary).padding(.horizontal, 20)
                            .fixedSize(horizontal: false, vertical: true)
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel(L10n.text("设置"))
                Button {
                    if selectedTab == .inProgress { clearingTasks = true }
                    else { library.clearCompletedTransfers() }
                } label: { Image(systemName: "paintbrush") }
                .disabled(records.isEmpty || library.isUpdatingTransferControls)
                .accessibilityLabel(selectedTab == .inProgress ? L10n.text("清除全部任务") : L10n.text("清空已传输记录"))
            }
        }
        .confirmationDialog(L10n.text("清除全部任务？"), isPresented: $clearingTasks, titleVisibility: .visible) {
            Button(L10n.text("清除全部任务"), role: .destructive) { library.clearAllTasks() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { Text(L10n.text("未完成的传输会停止，手表上的音乐会保留。")) }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-preview-transfers-completed") { selectedTab = .stored }
        }
        #endif
    }

    private var queueControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                queueCount.fixedSize()
                Spacer()
                queueButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                queueCount
                queueButton
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var queueCount: some View {
        Text(L10n.format("%lld 项任务", records.count)).font(.subheadline).foregroundStyle(AppPalette.textSecondary)
    }

    private var queueButton: some View {
        Button { library.toggleTransfers() } label: {
            HStack(spacing: 6) {
                if library.isUpdatingTransferControls { ProgressView().controlSize(.small) }
                else { Image(systemName: library.shouldStartTransfers() ? "play.fill" : "pause.fill") }
                Text(library.shouldStartTransfers() ? L10n.text("全部开始") : L10n.text("全部暂停"))
            }.font(.subheadline.weight(.medium)).frame(minHeight: 36)
        }
        .disabled(!library.canToggleTransfers())
        .buttonStyle(.bordered).tint(AppPalette.accent)
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                title.fixedSize()
                Spacer(minLength: 4)
                if showsEstimate, let estimate = progress.remainingEstimate {
                    estimateLabel(estimate).fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                title
                if showsEstimate, let estimate = progress.remainingEstimate {
                    estimateLabel(estimate)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text(L10n.text("传输")).font(.largeTitle.bold()).foregroundStyle(AppPalette.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func estimateLabel(_ estimate: String) -> some View {
        Text(L10n.message(estimate)).font(.subheadline).foregroundStyle(AppPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(L10n.format("全部任务%@", L10n.message(estimate)))
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
            return record.method == .localNetwork ? L10n.text("正在校验和保存") : L10n.text("等待手表确认")
        }
        guard record.state == .queued else { return record.state.title }
        if isCurrent && isPreparing && record.lanSessionID == nil { return L10n.text("正在准备…") }
        if fraction >= 1 { return L10n.text("等待手表确认") }
        if metrics?.isTransferring == true { return L10n.text("传输中") }
        if hasStarted { return L10n.text("等待继续传输") }
        if isCurrent && isAwaitingAcceptance { return L10n.text("等待手表接收") }
        return L10n.text("等待传输")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.state.symbol).font(.title2).foregroundStyle(tint)
                    .frame(width: 26, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.songTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(status).font(.caption).foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                    if record.state == .failed && !record.message.isEmpty && record.message != record.state.title {
                        Text(L10n.message(record.message)).font(.caption2).foregroundStyle(AppPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if record.state == .stored && record.totalBytes > 0 {
                        Text(transferBytes(record.totalBytes)).font(.caption2).foregroundStyle(AppPalette.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                controls
            }
            if (record.state == .queued || record.state == .paused) && hasStarted {
                ProgressView(value: fraction).tint(AppPalette.accent)
                    .accessibilityLabel(L10n.text("传输进度")).accessibilityValue("\(Int(fraction * 100))%")
                HStack {
                    if let metrics, metrics.totalBytes > 0 {
                        Text("\(transferBytes(metrics.completedBytes)) / \(transferBytes(metrics.totalBytes))")
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(fraction * 100))%")
                }.font(.caption2.monospacedDigit()).foregroundStyle(AppPalette.textSecondary)
                if let metrics, metrics.isTransferring {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            speedLabel(metrics).fixedSize()
                            Spacer(minLength: 8)
                            remainingLabel(metrics).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            speedLabel(metrics)
                            remainingLabel(metrics)
                        }
                    }.font(.caption2.monospacedDigit()).foregroundStyle(AppPalette.textSecondary)
                }
            }
        }
        .padding(16).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    private func speedLabel(_ metrics: TransferMetrics) -> some View {
        let value: String
        if let speed = metrics.bytesPerSecond, speed.isFinite, speed > 0 {
            value = L10n.format("约 %@/秒", transferBytes(Int64(min(speed, 1_000_000_000_000))))
        } else { value = L10n.text("正在估算速度…") }
        return Text(value).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func remainingLabel(_ metrics: TransferMetrics) -> some View {
        if let eta = metrics.estimatedTimeRemaining, eta.isFinite, eta > 0 {
            Text(L10n.format("剩余约 %@", transferDuration(eta)))
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    .accessibilityLabel((shouldStart ? L10n.format("继续传输 %@", record.songTitle) : L10n.format("暂停传输 %@", record.songTitle)))
                }
                Button { library.cancel(record) } label: {
                    Image(systemName: "xmark.circle").font(.title3).frame(width: 40, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(AppPalette.textSecondary).disabled(controlsBusy)
                .accessibilityLabel(L10n.format("取消传输 %@", record.songTitle))
            }
        } else if record.state != .stored && !record.state.isPending {
            Button(L10n.text("重试")) { library.retry(record) }
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
    if value < 60 { return L10n.format("%lld 秒", max(1, value)) }
    if value < 3_600 { return L10n.format("%lld 分 %lld 秒", value / 60, value % 60) }
    return L10n.format("%lld 小时 %lld 分", value / 3_600, (value % 3_600) / 60)
}
