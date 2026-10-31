import SwiftUI

struct LANTransferView: View {
    let reception: LANReceptionStatus
    let cancel: () -> Void
    @Environment(\.watchContentViewport) private var viewport

    private var progress: Double {
        min(1, max(0, Double(reception.completedBytes) / Double(max(1, reception.totalBytes))))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let landscape = viewport?.orientation.isLandscape ?? (size.width > size.height)
            let layout = LANTransferLayout(size: size, clockFrame: viewport?.clockFrame ?? .zero, landscape: landscape)
            content(size: size, landscape: landscape, layout: layout)
                .padding(.top, 6).padding(.bottom, layout.bottom)
                .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .foregroundStyle(AppPalette.textPrimary)
        .background(AppPalette.background)
    }

    private func content(size: CGSize, landscape: Bool, layout: LANTransferLayout) -> some View {
        let compact = size.height < 215
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi").foregroundStyle(AppPalette.accent)
                        Text(L10n.text("接收中")).fontWeight(.medium)
                    }.fixedSize()
                    Text(L10n.text("接收中")).fontWeight(.medium).fixedSize()
                }
                Spacer(minLength: 0)
            }.font(.system(size: 11)).frame(height: 16)
                .padding(.leading, layout.headerLeading).padding(.trailing, layout.headerTrailing)
            VStack(spacing: 6) {
                if landscape {
                    HStack(spacing: 10) {
                        percentage(compact: compact)
                        VStack(alignment: .leading, spacing: 2) {
                            fileName(lines: 2)
                            queueCount
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 3) {
                        percentage(compact: compact)
                        HStack(spacing: 7) {
                            fileName(lines: compact ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                            queueCount.fixedSize()
                        }
                    }
                }
                ProgressView(value: progress).tint(AppPalette.accent).frame(height: 4).accessibilityLabel(L10n.text("接收进度"))
            }
            .padding(.leading, layout.middleLeading).padding(.trailing, layout.middleTrailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: cancel) {
                Label(L10n.text("取消"), systemImage: "xmark").font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("取消局域网传输"))
                .padding(.leading, layout.cancelLeading).padding(.trailing, layout.cancelTrailing)
        }
    }

    private var queueCount: some View {
        Text("\(reception.fileIndex)/\(reception.fileCount)")
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(AppPalette.textSecondary)
            .accessibilityLabel(L10n.format("第 %@ 首，共 %@ 首", String(describing: reception.fileIndex), String(describing: reception.fileCount)))
    }

    private func percentage(compact: Bool) -> some View {
        Text(reception.isPaused ? L10n.text("已暂停") : (reception.isSaving ? L10n.text("保存中") : "\(Int(progress * 100))%"))
            .font(.system(size: reception.isSaving || reception.isPaused ? 23 : (compact ? 34 : 44), weight: .semibold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(AppPalette.accent)
    }

    private func fileName(lines: Int) -> some View {
        Text((reception.fileName as NSString).deletingPathExtension)
            .font(.system(size: 13)).lineLimit(lines).truncationMode(.middle)
    }
}

/// Clock clearance affects only the header, middle group, or bottom action it
/// intersects. The transfer canvas keeps the watch's full width and height.
private struct LANTransferLayout {
    var headerLeading: CGFloat = 14
    var headerTrailing: CGFloat = 14
    var middleLeading: CGFloat = 14
    var middleTrailing: CGFloat = 14
    var cancelLeading: CGFloat = 14
    var cancelTrailing: CGFloat = 14
    var bottom: CGFloat = 10

    init(size: CGSize, clockFrame: CGRect, landscape: Bool) {
        guard !clockFrame.isEmpty else { return }
        let clockOnLeading = clockFrame.midX < size.width / 2
        let clockOnBottom = clockFrame.midY > size.height / 2
        let leadingClearance = max(14, clockFrame.maxX + 6)
        let trailingClearance = max(14, size.width - clockFrame.minX + 6)
        if clockFrame.intersects(CGRect(x: 0, y: 6, width: size.width, height: 16)) {
            if clockOnLeading { headerLeading = leadingClearance }
            else { headerTrailing = trailingClearance }
        }
        if landscape {
            if clockOnLeading { middleLeading = leadingClearance }
            else { middleTrailing = trailingClearance }
            if clockOnBottom {
                if clockOnLeading { cancelLeading = leadingClearance }
                else { cancelTrailing = trailingClearance }
            }
        } else if clockOnBottom {
            bottom = max(10, size.height - clockFrame.minY + 6)
        }
    }
}
