import SwiftUI

struct PrivacyConsentGate: View {
    @StateObject private var consent = PrivacyConsentController()

    var body: some View {
        Group {
            if consent.isAccepted {
                AuthorizedPhoneContent(withdrawConsent: consent.withdraw)
            } else {
                VStack(spacing: 22) {
                    PhoneBrandMark(side: 88)
                    Text(PhoneAppInformation.displayName).font(.title2.weight(.semibold))
                    Button(L10n.text("查看协议"), action: consent.review)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppPalette.background)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { consent.isPresentingConsent },
            set: { _ in }
        )) {
            PrivacyConsentView(agree: consent.agree, cancel: consent.cancel)
                .interactiveDismissDisabled()
        }
    }
}

private struct PrivacyConsentView: View {
    let agree: () -> Void
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var documentsAvailable: Bool {
        LegalDocument.privacy.fileURL != nil && LegalDocument.terms.fileURL != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PhoneBrandMark(side: 64).padding(.top, 20)
                    Text(L10n.text("让音乐随身相伴"))
                        .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text(L10n.text("开始前，请阅读隐私协议和用户协议。"))
                        .foregroundStyle(AppPalette.textSecondary)

                    VStack(alignment: .leading, spacing: 18) {
                        privacyPoint("music.note", title: L10n.text("音乐由你选择"), detail: L10n.text("导入的音乐和播放记录保存在设备上。"))
                        privacyPoint("applewatch", title: L10n.text("在你的设备间传输"), detail: L10n.text("使用局域网和系统连接向配对的手表发送音乐。"))
                        privacyPoint("person.crop.circle.badge.checkmark", title: L10n.text("无需注册账号"), detail: L10n.text("没有广告，也不进行跨应用追踪。"))
                    }.padding(.vertical, 4)

                    VStack(spacing: 0) {
                        agreementLink(.privacy)
                        Divider().padding(.leading, 16)
                        agreementLink(.terms)
                    }
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18))

                    Text(L10n.text("点击“同意并继续”，表示你已阅读并同意《隐私协议》和《用户协议》。"))
                        .font(.footnote).foregroundStyle(AppPalette.textSecondary)
                    if !documentsAvailable {
                        Text(L10n.text("协议文件暂时无法读取，请重新打开应用后重试。"))
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppPalette.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let actionLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                actionLayout {
                    Button(action: cancel) {
                        Text(L10n.text("取消"))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 12)
                            .foregroundStyle(AppPalette.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                            .contentShape(RoundedRectangle(cornerRadius: 15))
                    }
                    Button(action: agree) {
                        Text(L10n.text("同意并继续"))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 12)
                            .foregroundStyle(AppPalette.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 15))
                            .contentShape(RoundedRectangle(cornerRadius: 15))
                    }
                    .disabled(!documentsAvailable)
                    .opacity(documentsAvailable ? 1 : 0.45)
                }
                .font(.body.weight(.semibold)).buttonStyle(.plain)
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .background(AppPalette.background)
            }
            .navigationTitle(L10n.text("隐私与协议")).navigationBarTitleDisplayMode(.inline)
        }
        .tint(AppPalette.accent)
    }

    private func privacyPoint(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.title3).foregroundStyle(AppPalette.accent)
                .frame(width: 25).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.subheadline).foregroundStyle(AppPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func agreementLink(_ document: LegalDocument) -> some View {
        NavigationLink {
            LegalDocumentView(document: document)
        } label: {
            HStack {
                Text(document.title).foregroundStyle(AppPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.textSecondary)
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
