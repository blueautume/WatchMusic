import SwiftUI
import WebKit

enum LegalDocument: String, CaseIterable {
    case privacy
    case terms
    case support

    var title: String {
        switch self {
        case .privacy: "隐私协议"
        case .terms: "用户协议"
        case .support: "技术支持"
        }
    }

    var fileURL: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "html", subdirectory: "Legal")
            ?? Bundle.main.url(forResource: rawValue, withExtension: "html")
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.openURL) private var openURL
    @State private var displayedTitle = ""

    var body: some View {
        Group {
            if let fileURL = document.fileURL {
                LegalWebView(fileURL: fileURL, openExternalURL: { openURL($0) },
                             updateTitle: { displayedTitle = $0 })
            } else {
                ContentUnavailableView("暂时无法打开协议", systemImage: "doc.text",
                                       description: Text("请重新打开应用后重试。"))
            }
        }
        .background(AppPalette.background)
        .navigationTitle(displayedTitle.isEmpty ? document.title : displayedTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The same HTML files are used in the app and on the deployable website.
/// Reading is offline; only a deliberate external link opens a browser.
private struct LegalWebView: UIViewRepresentable {
    let fileURL: URL
    let openExternalURL: (URL) -> Void
    let updateTitle: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openExternalURL: openExternalURL, updateTitle: updateTitle)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let openExternalURL: (URL) -> Void
        private let updateTitle: (String) -> Void
        private let permittedFiles: Set<URL>

        init(openExternalURL: @escaping (URL) -> Void, updateTitle: @escaping (String) -> Void) {
            self.openExternalURL = openExternalURL
            self.updateTitle = updateTitle
            permittedFiles = Set(LegalDocument.allCases.compactMap(\.fileURL).map(Self.canonicalFile))
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel); return
            }
            if url.isFileURL, permittedFiles.contains(Self.canonicalFile(url)) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated,
                   ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    openExternalURL(url)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let file = webView.url?.deletingPathExtension().lastPathComponent,
                  let document = LegalDocument(rawValue: file) else { return }
            updateTitle(document.title)
        }

        private static func canonicalFile(_ url: URL) -> URL {
            // Rebuild from the file path so in-page fragments do not prevent
            // normal navigation, while only the exact packaged files pass.
            URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
        }
    }
}
