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
            let size = viewport?.size ?? geometry.size
            content(size: size, landscape: viewport?.orientation.isLandscape ?? (size.width > size.height))
                .padding(.horizontal, 14)
                .padding(.top, 2).padding(.bottom, 10)
                .frame(width: size.width, height: size.height)
                .position(viewport?.center(in: geometry) ?? CGPoint(x: size.width / 2, y: size.height / 2))
        }
        .ignoresSafeArea()
        .foregroundStyle(AppPalette.textPrimary)
        .background(AppPalette.background)
    }

    private func content(size: CGSize, landscape: Bool) -> some View {
        let compact = size.height < 180
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wifi").foregroundStyle(AppPalette.accent)
                Text("正在接收").fontWeight(.medium)
                Spacer(minLength: 0)
                Text("\(reception.fileIndex)/\(reception.fileCount)").monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("第 \(reception.fileIndex) 首，共 \(reception.fileCount) 首")
            }.font(.system(size: 11)).frame(height: 16)
            Spacer(minLength: 0)
            if landscape {
                HStack(spacing: 10) {
                    percentage(compact: compact)
                    fileName(lines: 2).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 3) {
                    percentage(compact: compact)
                    fileName(lines: compact ? 1 : 2).frame(maxWidth: .infinity)
                }
            }
            ProgressView(value: progress).tint(AppPalette.accent).frame(height: 4).accessibilityLabel("接收进度")
            Spacer(minLength: 0)
            Button(action: cancel) {
                Label("取消", systemImage: "xmark").font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel("取消局域网传输")
        }
    }

    private func percentage(compact: Bool) -> some View {
        Text(reception.isPaused ? "已暂停" : (reception.isSaving ? "保存中" : "\(Int(progress * 100))%"))
            .font(.system(size: reception.isSaving || reception.isPaused ? 23 : (compact ? 34 : 44), weight: .semibold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(AppPalette.accent)
    }

    private func fileName(lines: Int) -> some View {
        Text((reception.fileName as NSString).deletingPathExtension)
            .font(.system(size: 13)).lineLimit(lines).truncationMode(.middle)
    }
}
