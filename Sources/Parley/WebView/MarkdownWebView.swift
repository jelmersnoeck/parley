import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let viewModel: PRViewModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "parley")
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView

        loadTemplate(webView: webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard !viewModel.markdownContent.isEmpty else { return }
        context.coordinator.loadContent(in: webView)

        // Handle scroll-to-line requests from the inspector
        if let line = viewModel.scrollTarget {
            context.coordinator.scrollToLine(line, in: webView)
            DispatchQueue.main.async { viewModel.scrollTarget = nil }
        }
    }

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(viewModel: viewModel)
    }

    private func loadTemplate(webView: WKWebView) {
        guard let resourceURL = Bundle.module.url(forResource: "Resources", withExtension: nil) else {
            print("Could not find Resources bundle")
            return
        }

        let templateURL = resourceURL.appendingPathComponent("markdown-template.html")
        webView.loadFileURL(templateURL, allowingReadAccessTo: resourceURL)
    }
}
