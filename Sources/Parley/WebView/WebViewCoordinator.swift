import Foundation
import WebKit

final class WebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let viewModel: PRViewModel
    weak var webView: WKWebView?
    private var templateLoaded = false
    private var pendingContentLoad = false

    /// Maximum allowed length for a draft comment body from JS input.
    private static let maxBodyLength = 100_000

    init(viewModel: PRViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        Task { @MainActor in
            switch action {
            case "addComment":
                guard let line = body["line"] as? Int,
                      let commentBody = body["body"] as? String,
                      let validated = Self.validatedBody(commentBody) else { return }
                let startLine = body["startLine"] as? Int
                let path = viewModel.prMetadata?.markdownFilePath ?? ""
                viewModel.addDraftComment(line: line, startLine: startLine, body: validated, path: path)
                reloadContent()

            case "submitReply":
                guard let commentId = body["commentId"] as? Int,
                      let replyBody = body["body"] as? String,
                      let validated = Self.validatedBody(replyBody) else { return }
                await viewModel.replyToThread(commentId: commentId, body: validated)

            case "editComment":
                guard let idString = body["id"] as? String,
                      let uuid = UUID(uuidString: idString),
                      let newBody = body["body"] as? String else { return }
                let truncated = String(newBody.prefix(Self.maxBodyLength))
                viewModel.updateDraftComment(id: uuid, body: truncated)
                reloadContent()

            case "removeComment":
                guard let idString = body["id"] as? String,
                      let uuid = UUID(uuidString: idString) else { return }
                viewModel.removeDraftComment(id: uuid)
                reloadContent()

            case "expandThread", "collapseThread":
                break

            default:
                break
            }
        }
    }

    // MARK: - Input validation

    /// Validates and truncates a body string from JS. Returns nil if empty after trimming.
    private static func validatedBody(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxBodyLength))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        templateLoaded = true

        // If content was waiting for the template to load, render it now
        if pendingContentLoad {
            pendingContentLoad = false
            Task { @MainActor in
                loadContent(in: webView)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        switch url.scheme {
        case "file", "about":
            return .allow
        default:
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }

    // MARK: - Content loading

    @MainActor
    func scrollToLine(_ line: Int, in webView: WKWebView) {
        guard templateLoaded else { return }
        webView.evaluateJavaScript("scrollToLine(\(line))") { _, _ in }
    }

    @MainActor
    func reloadContent() {
        guard let webView else { return }
        loadContent(in: webView)
    }

    @MainActor
    func loadContent(in webView: WKWebView) {
        // Don't call JS until the HTML template has finished loading
        guard templateLoaded else {
            pendingContentLoad = true
            return
        }

        let markdown = viewModel.markdownContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")

        let threadsJSON = threadsToJSON(viewModel.commentThreads)
        let draftsJSON = draftsToJSON(viewModel.draftComments)

        let js = "renderMarkdown(`\(markdown)`, \(threadsJSON), \(draftsJSON));"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("JS error: \(error)")
            }
        }
    }

    private func threadsToJSON(_ threads: [CommentThread]) -> String {
        let items = threads.map { thread in
            let comments = thread.comments.map { c in
                "{\"id\":\(c.id),\"author\":\"\(escapeJSON(c.author))\",\"body\":\"\(escapeJSON(c.body))\",\"createdAt\":\"\(ISO8601DateFormatter().string(from: c.createdAt))\"}"
            }.joined(separator: ",")
            return "{\"id\":\(thread.id),\"line\":\(thread.line),\"comments\":[\(comments)]}"
        }.joined(separator: ",")
        return "[\(items)]"
    }

    private func draftsToJSON(_ drafts: [DraftComment]) -> String {
        let items = drafts.map { d in
            "{\"id\":\"\(d.id)\",\"line\":\(d.line),\"body\":\"\(escapeJSON(d.body))\"}"
        }.joined(separator: ",")
        return "[\(items)]"
    }

    private func escapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }
}
