import Foundation
import os
import WebKit

final class WebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let viewModel: PRViewModel
    weak var webView: WKWebView?
    private var templateLoaded = false
    private var pendingContentLoad = false
    private var jsErrorCount = 0

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.parley",
        category: "WebViewCoordinator"
    )

    init(viewModel: PRViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            Self.logger.warning("Malformed JS message: expected {action: String, ...}, got \(String(describing: message.body))")
            return
        }

        // Validate message keys are all strings (reject non-string keys that could indicate injection)
        let knownActions: Set<String> = ["addComment", "submitReply", "editComment", "removeComment", "expandThread", "collapseThread", "logError"]
        guard knownActions.contains(action) else {
            Self.logger.debug("Unknown JS action: \(action)")
            return
        }

        Task { @MainActor in
            switch action {
            case "addComment":
                guard let line = body["line"] as? Int,
                      let commentBody = body["body"] as? String,
                      let validated = Self.validatedBody(commentBody) else {
                    Self.logger.warning("addComment: invalid payload — line or body missing/empty")
                    return
                }
                let startLine = body["startLine"] as? Int
                let path = viewModel.prMetadata?.markdownFilePath ?? ""
                viewModel.addDraftComment(line: line, startLine: startLine, body: validated, path: path)
                reloadContent()

            case "submitReply":
                guard let commentId = body["commentId"] as? Int,
                      let replyBody = body["body"] as? String,
                      let validated = Self.validatedBody(replyBody) else {
                    Self.logger.warning("submitReply: invalid payload — commentId or body missing/empty")
                    return
                }
                await viewModel.replyToThread(commentId: commentId, body: validated)

            case "editComment":
                guard let uuid = Self.parseUUID(from: body, label: "editComment") else {
                    return
                }
                guard let newBody = body["body"] as? String else {
                    Self.logger.warning("editComment: missing 'body' field")
                    return
                }
                // Sanitize + truncate, but allow empty (model treats empty as delete)
                let sanitized = Self.sanitizedBody(newBody)
                viewModel.updateDraftComment(id: uuid, body: sanitized)
                Self.logger.debug("editComment: updated draft \(uuid)")
                reloadContent()

            case "removeComment":
                guard let uuid = Self.parseUUID(from: body, label: "removeComment") else {
                    return
                }
                viewModel.removeDraftComment(id: uuid)
                Self.logger.debug("removeComment: removed draft \(uuid)")
                reloadContent()

            case "logError":
                let source = body["source"] as? String ?? "unknown"
                let detail = body["detail"] as? String ?? "(no detail)"
                jsErrorCount += 1
                Self.logger.error("JS error (#\(self.jsErrorCount)) [\(source)]: \(detail)")

            case "expandThread", "collapseThread":
                break

            default:
                break
            }
        }
    }

    // MARK: - Input validation

    /// Extracts and validates a UUID from a message body's "id" field. Logs on failure.
    private static func parseUUID(from body: [String: Any], label: String) -> UUID? {
        guard let idString = body["id"] as? String else {
            logger.warning("\(label): missing 'id' field")
            return nil
        }
        guard let uuid = UUID(uuidString: idString) else {
            logger.warning("\(label): malformed UUID '\(idString)'")
            return nil
        }
        return uuid
    }

    /// Sanitizes, trims, and truncates a body string. Returns nil if empty — use for actions
    /// where empty body is invalid (addComment, submitReply).
    private static func validatedBody(_ raw: String) -> String? {
        let result = sanitizedBody(raw)
        guard !result.isEmpty else { return nil }
        return result
    }

    /// Sanitizes and truncates a body string. Allows empty — use for editComment where
    /// empty body means "delete" (handled by the model).
    ///
    /// Strips null bytes + C0/C1 control characters (preserving tab, newline, CR),
    /// trims whitespace, and Unicode-safe truncates to maxBodyLength using Character
    /// boundaries (never splits a grapheme cluster or multi-byte sequence).
    private static func sanitizedBody(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            // Keep tab (\t = 0x09), newline (\n = 0x0A), carriage return (\r = 0x0D)
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return true
            case 0x00...0x1F, 0x7F...0x9F:
                return false
            default:
                return true
            }
        }
        let trimmed = String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        // Unicode-safe truncation: String.prefix on Character count respects
        // grapheme cluster boundaries — never splits multi-byte sequences.
        return String(trimmed.prefix(PRViewModel.maxBodyLength))
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
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error {
                self?.jsErrorCount += 1
                Self.logger.error("JS render error (#\(self?.jsErrorCount ?? 0)): \(error)")
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
