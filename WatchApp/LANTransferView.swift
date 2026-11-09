import SwiftUI

struct LANTransferView: View {
    let reception: LANReceptionStatus
    let cancel: () -> Void
    @Environment(\.watchContentViewport) private var viewport
    @Environment(\.isLuminanceReduced) private var reducedLuminance

    var body: some View {
        GeometryReader { geometry in
            let layout = LANTransferLayout(size: geometry.size, clockFrame: viewport?.clockFrame ?? .zero)
            ZStack {
                // Keep the same scroll view mounted across wrist-down/up so
                // its position and stable file identities survive Always On.
                activeContent(layout: layout)
                    .opacity(reducedLuminance ? 0 : 1)
                    .allowsHitTesting(!reducedLuminance)
                    .accessibilityHidden(reducedLuminance)
                if reducedLuminance {
                    reducedContent(layout: layout)
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 6).padding(.bottom, layout.bottom)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .foregroundStyle(AppPalette.textPrimary)
        .background(reducedLuminance ? Color.black : AppPalette.background)
        .transaction { transaction in
            if reducedLuminance { transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }

    private func activeContent(layout: LANTransferLayout) -> some View {
        VStack(spacing: 6) {
            if layout.compactControls { compactSummary(layout: layout) }
            else { summary(layout: layout, reduced: false) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(reception.files) { file in fileRow(file) }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
            .defaultScrollAnchor(initialScrollAnchor)
            .padding(.leading, layout.listLeading).padding(.trailing, layout.listTrailing)
            .accessibilityLabel(L10n.text("本批任务"))
            if !layout.compactControls {
                cancelButton(compact: false)
                    .padding(.leading, layout.cancelLeading).padding(.trailing, layout.cancelTrailing)
            }
        }
    }

    private func cancelButton(compact: Bool) -> some View {
        Button(action: cancel) {
            Group {
                if compact { Image(systemName: "xmark") }
                else { Label(L10n.text("取消剩余任务"), systemImage: "xmark") }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: compact ? 44 : .infinity).frame(height: 44)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(reception.pendingCount == 0)
        .accessibilityLabel(L10n.text("取消本批剩余传输"))
    }

    private func compactSummary(layout: LANTransferLayout) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryTitle).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppPalette.textSecondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(reception.batchProgress * 100))%")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppPalette.accent)
                        .accessibilityLabel(L10n.text("本批接收进度"))
                        .accessibilityValue("\(Int(reception.batchProgress * 100))%")
                    Label("\(reception.storedCount)/\(reception.fileCount)", systemImage: "checkmark")
                        .font(.system(size: 10)).foregroundStyle(AppPalette.textSecondary)
                        .accessibilityLabel(L10n.format("已保存 %@", "\(reception.storedCount)/\(reception.fileCount)"))
                }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            }.frame(maxWidth: .infinity, alignment: .leading)
            cancelButton(compact: true)
        }
        .frame(height: 50, alignment: .bottom)
        .padding(.leading, layout.headerLeading).padding(.trailing, layout.headerTrailing)
    }

    private func summary(layout: LANTransferLayout, reduced: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryTitle).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(reduced ? Color.white.opacity(0.7) : AppPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("\(Int(reception.batchProgress * 100))%")
                    .font(.system(size: 28, weight: reduced ? .regular : .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    .foregroundStyle(reduced ? Color.white : AppPalette.accent)
                    .accessibilityLabel(L10n.text("本批接收进度"))
                    .accessibilityValue("\(Int(reception.batchProgress * 100))%")
            }
            .frame(width: layout.summaryWidth, alignment: .leading)
            Spacer(minLength: 0)
            Text(L10n.format("已保存 %@", "\(reception.storedCount)/\(reception.fileCount)"))
                .font(.system(size: 11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(reduced ? Color.white.opacity(0.7) : AppPalette.textSecondary)
        }
        .frame(height: 50, alignment: .bottom)
        .padding(.leading, layout.headerLeading).padding(.trailing, layout.headerTrailing)
    }

    private func fileRow(_ file: LANReceptionFileStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((file.fileName as NSString).deletingPathExtension)
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(phaseTitle(file.phase)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(file.progress * 100))%").monospacedDigit()
            }
            .font(.system(size: 10)).foregroundStyle(phaseColor(file.phase))
            GeometryReader { geometry in
                Capsule().fill(AppPalette.surface)
                    .overlay(alignment: .leading) {
                        Capsule().fill(phaseColor(file.phase))
                            .frame(width: geometry.size.width * file.progress)
                    }
            }.frame(height: 3)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func reducedContent(layout: LANTransferLayout) -> some View {
        VStack(spacing: 6) {
            summary(layout: layout, reduced: true)
            VStack(spacing: 10) {
                Text(L10n.format("剩余 %@ 首", String(reception.pendingCount)))
                    .font(.system(size: 17)).monospacedDigit()
                Text("\(transferBytes(reception.batchReceivedBytes)) / \(transferBytes(reception.batchTotalBytes))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                if reception.failedCount > 0 || reception.cancelledCount > 0 {
                    Text(L10n.format("失败 %@ · 已取消 %@", String(reception.failedCount), String(reception.cancelledCount)))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, layout.listLeading).padding(.trailing, layout.listTrailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryTitle: String {
        if reception.allStored { return L10n.text("已保存") }
        if reception.isFinished { return L10n.text("接收结束") }
        if reception.isBatchPaused { return L10n.text("已暂停") }
        if reception.validatingCount == reception.pendingCount { return L10n.text("保存中") }
        return L10n.text("接收中")
    }

    private func phaseTitle(_ phase: LANBackgroundTransferState.Phase) -> String {
        switch phase {
        case .queued: L10n.text("等待接收")
        case .downloading: L10n.text("接收中")
        case .validating: L10n.text("保存中")
        case .paused: L10n.text("已暂停")
        case .stored: L10n.text("已保存")
        case .failed: L10n.text("接收失败")
        case .cancelled: L10n.text("已取消")
        }
    }

    private func phaseColor(_ phase: LANBackgroundTransferState.Phase) -> Color {
        switch phase {
        case .downloading, .validating: AppPalette.accent
        case .stored: .green
        case .failed: .orange
        case .queued, .paused, .cancelled: AppPalette.textSecondary
        }
    }

    private func transferBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var initialScrollAnchor: UnitPoint {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-preview-lan-tail") ? .bottom : .top
        #else
        .top
        #endif
    }
}

/// Reserve the clock only in the bands it actually intersects. The summary's
/// right-hand count sits below the top clock; the percentage fits to its left.
private struct LANTransferLayout {
    var compactControls: Bool
    var headerLeading: CGFloat = 14
    var headerTrailing: CGFloat = 14
    var summaryWidth: CGFloat
    var listLeading: CGFloat = 14
    var listTrailing: CGFloat = 14
    var cancelLeading: CGFloat = 14
    var cancelTrailing: CGFloat = 14
    var bottom: CGFloat = 10

    init(size: CGSize, clockFrame: CGRect) {
        compactControls = size.width > size.height
        summaryWidth = min(110, size.width * 0.45)
        guard !clockFrame.isEmpty else { return }
        let clockOnLeading = clockFrame.midX < size.width / 2
        let clockOnBottom = clockFrame.midY > size.height / 2
        if clockOnBottom { compactControls = true }
        let leadingClearance = max(14, clockFrame.maxX + 6)
        let trailingClearance = max(14, size.width - clockFrame.minX + 6)
        if clockOnBottom, clockFrame.width > size.width * 0.4 {
            bottom = max(10, size.height - clockFrame.minY + 6)
        }
        let headerBand = CGRect(x: 0, y: 6, width: size.width, height: 50)
        if clockFrame.intersects(headerBand) {
            if clockOnLeading { headerLeading = leadingClearance }
            else { summaryWidth = max(40, min(summaryWidth, clockFrame.minX - 20)) }
        }
        let countBand = CGRect(x: 0, y: 42, width: size.width, height: 14)
        if !clockOnLeading, clockFrame.intersects(countBand) { headerTrailing = trailingClearance }
        let listBand = CGRect(x: 0, y: 62, width: size.width, height: max(0, size.height - bottom - (compactControls ? 62 : 112)))
        if clockFrame.intersects(listBand) {
            if clockOnLeading { listLeading = leadingClearance }
            else { listTrailing = trailingClearance }
        }
        let cancelBand = CGRect(x: 0, y: size.height - bottom - 44, width: size.width, height: 44)
        if clockFrame.intersects(cancelBand) {
            if clockOnLeading { cancelLeading = leadingClearance }
            else { cancelTrailing = trailingClearance }
        }
    }
}
