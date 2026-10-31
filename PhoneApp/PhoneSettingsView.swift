import SwiftUI

private struct WithdrawPrivacyConsentKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var withdrawPrivacyConsent: (() -> Void)? {
        get { self[WithdrawPrivacyConsentKey.self] }
        set { self[WithdrawPrivacyConsentKey.self] = newValue }
    }
}

enum PhoneAppInformation {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? L10n.text("随身音乐")
    }

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    static let supportURL = URL(string: "mailto:2114581274@qq.com")!
}

struct PhoneSettingsView: View {
    #if DEBUG && targetEnvironment(simulator)
    @State private var previewDestination: String?
    #endif

    var body: some View {
        List {
            NavigationLink(L10n.text("隐私协议")) { PrivacyAgreementsView() }
                .listRowBackground(AppPalette.surface)
            NavigationLink(L10n.text("关于")) { PhoneAboutView() }
                .listRowBackground(AppPalette.surface)
        }
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle(L10n.text("设置")).navigationBarTitleDisplayMode(.inline)
        #if DEBUG && targetEnvironment(simulator)
        .navigationDestination(isPresented: Binding(
            get: { previewDestination != nil }, set: { if !$0 { previewDestination = nil } }
        )) {
            switch previewDestination {
            case "about": PhoneAboutView()
            case "agreements": PrivacyAgreementsView()
            case "privacy": LegalDocumentView(document: .privacy)
            case "terms": LegalDocumentView(document: .terms)
            case "support": LegalDocumentView(document: .support)
            default: EmptyView()
            }
        }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-preview-about") { previewDestination = "about" }
            else if arguments.contains("-preview-agreements") { previewDestination = "agreements" }
            else if arguments.contains("-preview-privacy-document") { previewDestination = "privacy" }
            else if arguments.contains("-preview-terms-document") { previewDestination = "terms" }
            else if arguments.contains("-preview-support-document") { previewDestination = "support" }
        }
        #endif
    }
}

private struct PrivacyAgreementsView: View {
    @Environment(\.withdrawPrivacyConsent) private var withdrawConsent
    @State private var confirmingWithdrawal = false

    var body: some View {
        List {
            Section {
                NavigationLink(LegalDocument.privacy.title) { LegalDocumentView(document: .privacy) }
                NavigationLink(LegalDocument.terms.title) { LegalDocumentView(document: .terms) }
            }.listRowBackground(AppPalette.surface)
            if withdrawConsent != nil {
                Section {
                    Button(L10n.text("撤回同意"), role: .destructive) { confirmingWithdrawal = true }
                }.listRowBackground(AppPalette.surface)
            }
        }
        .scrollContentBackground(.hidden).background(AppPalette.background)
        .navigationTitle(L10n.text("隐私协议")).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(L10n.text("撤回协议同意？"), isPresented: $confirmingWithdrawal, titleVisibility: .visible) {
            Button(L10n.text("撤回同意并停用"), role: .destructive) { withdrawConsent?() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("将停止播放和传输并返回协议页面。设备上的音乐会保留。"))
        }
    }
}

private struct PhoneAboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PhoneBrandMark(side: 88)
                Text(PhoneAppInformation.displayName).font(.title2.weight(.semibold))
                Text(L10n.format("版本 %@", PhoneAppInformation.version))
                    .font(.subheadline).foregroundStyle(AppPalette.textSecondary)
                Text(L10n.text("把喜欢的音乐放进手表，随时离线聆听。"))
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(AppPalette.textSecondary).padding(.top, 4)
                Text(L10n.text("李浩（个人开发者）"))
                    .font(.footnote).foregroundStyle(AppPalette.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Link(L10n.text("技术支持"), destination: PhoneAppInformation.supportURL)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity).padding(28).padding(.top, 28)
        }
        .background(AppPalette.background)
        .navigationTitle(L10n.text("关于")).navigationBarTitleDisplayMode(.inline)
    }
}

struct PhoneBrandMark: View {
    let side: CGFloat

    var body: some View {
        Image("BrandMark").resizable().scaledToFit()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}
