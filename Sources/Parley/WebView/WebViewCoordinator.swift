import Foundation
import os
import WebKit

final class WebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let viewModel: PRViewModel
    weak var webView: WKWebView?
    private var templateLoaded = false
    private var pendingContentLoad = false

    /// Tracks JS error count for production monitoring and alerting on rendering issues.
    /// Bounded by `incrementErrorCount()` to prevent overflow in long-running sessions.
    private(set) var jsErrorCount = 0

    /// Tracks validation failures (bad UUIDs, out-of-range lines, sanitization hits)
    /// for monitoring. Frequent failures may indicate injection attacks or client bugs.
    private(set) var validationFailureCount = 0

    /// Consecutive JS render eval failures. When this hits `maxConsecutiveRenderFailures`,
    /// complex rendering is skipped to avoid thrashing a broken WebKit context.
    private(set) var consecutiveRenderFailures = 0

    /// Security control: only these actions are processed from JS messages.
    /// Any action not in this set is rejected with a warning log.
    private static let knownActions: Set<String> = [
        "addComment", "submitReply", "editComment", "removeComment",
        "expandThread", "collapseThread", "logError",
    ]

    /// Maximum reasonable line number to accept from JS messages.
    /// Files beyond 1M lines are implausible; anything higher is likely injection.
    static let maxLineNumber = 1_000_000

    /// Maximum input length (in UTF-8 bytes) to process through Unicode scalar
    /// filtering. Inputs beyond this are truncated before sanitization to prevent
    /// resource exhaustion. Configurable for deployment scenarios with larger payloads.
    static let maxInputBytes = 1_000_000

    /// Error count threshold for health-monitoring warnings. Initial warning fires
    /// at this count; subsequent warnings use exponential backoff (2x intervals).
    static let errorWarningInterval = 1_000

    /// Maximum consecutive JS render failures before entering degraded mode.
    /// Resets to 0 on any successful render.
    static let maxConsecutiveRenderFailures = 5

    /// Maximum length for log strings from untrusted JS context. Prevents
    /// injection of oversized strings into the logging system.
    private static let maxLogStringLength = 500

    /// Next error count threshold for warning. Doubles after each warning
    /// to implement exponential backoff on log frequency.
    private var nextErrorWarningThreshold = errorWarningInterval

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.parley",
        category: "WebViewCoordinator"
    )

    init(viewModel: PRViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Validate structure before parsing fields — reject non-dict payloads early
        guard let body = message.body as? [String: Any] else {
            Self.logger.warning("Malformed JS message: expected [String: Any], got type \(type(of: message.body))")
            return
        }

        guard let action = body["action"] as? String else {
            Self.logger.warning("Malformed JS message: missing or non-string 'action' key (keys: \(body.keys.sorted().joined(separator: ", ")))")
            return
        }

        guard Self.knownActions.contains(action) else {
            Self.logger.warning("Unknown JS action rejected: \(action)")
            return
        }

        Task { @MainActor in
            switch action {
            case "addComment":
                guard let line = body["line"] as? Int,
                      self.isValidLine(line, label: "addComment"),
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
                guard let uuid = self.parseUUID(from: body, label: "editComment") else {
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
                guard let uuid = self.parseUUID(from: body, label: "removeComment") else {
                    return
                }
                viewModel.removeDraftComment(id: uuid)
                Self.logger.debug("removeComment: removed draft \(uuid)")
                reloadContent()

            case "logError":
                let rawSource = body["source"] as? String ?? "unknown"
                let rawDetail = body["detail"] as? String ?? "(no detail)"
                let source = Self.sanitizeLogString(rawSource, maxLength: Self.maxLogStringLength)
                let detail = Self.sanitizeLogString(rawDetail, maxLength: Self.maxLogStringLength)
                incrementErrorCount()
                Self.logger.error("JS error (#\(self.jsErrorCount)) [\(source)]: \(detail)")

            case "expandThread", "collapseThread":
                break

            default:
                break
            }
        }
    }

    // MARK: - Input validation

    /// Validates that a line number is positive and within reasonable bounds.
    private func isValidLine(_ line: Int, label: String) -> Bool {
        guard line > 0, line <= Self.maxLineNumber else {
            Self.logger.warning("\(label): line \(line) out of valid range 1...\(Self.maxLineNumber)")
            incrementValidationFailure()
            return false
        }
        return true
    }

    /// Extracts and validates a UUID from a message body's "id" field. Logs on failure.
    private func parseUUID(from body: [String: Any], label: String) -> UUID? {
        guard let idString = body["id"] as? String else {
            Self.logger.warning("\(label): missing 'id' field")
            incrementValidationFailure()
            return nil
        }
        guard let uuid = UUID(uuidString: idString) else {
            Self.logger.warning("\(label): malformed UUID '\(idString)'")
            incrementValidationFailure()
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
    /// Pipeline: oversized truncation → control char stripping → trim → length truncation.
    /// Each stage is a separate function for testability.
    static func sanitizedBody(_ raw: String) -> String {
        let bounded = truncateOversizedInput(raw)
        let stripped = stripControlCharacters(bounded)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(PRViewModel.maxBodyLength))
    }

    /// Truncates inputs exceeding `maxInputBytes` before processing to prevent DoS
    /// through resource exhaustion during Unicode scalar iteration.
    static func truncateOversizedInput(_ raw: String) -> String {
        guard raw.utf8.count > maxInputBytes else { return raw }
        logger.warning("truncateOversizedInput: input too large (\(raw.utf8.count) bytes), truncating")
        return String(raw.prefix(maxInputBytes))
    }

    /// Single-pass filter over unicodeScalars: strips null bytes + C0/C1 control
    /// characters (preserving tab 0x09 and newline 0x0A; CR 0x0D is stripped as it's
    /// unnecessary in markdown and could be used in injection combos).
    ///
    /// Ranges stripped: C0 0x00-0x08, 0x0B-0x1F (skip tab 0x09, newline 0x0A),
    /// DEL 0x7F, C1 0x80-0x9F. When no characters are stripped, returns the
    /// original string without allocation.
    static func stripControlCharacters(_ input: String) -> String {
        var didStrip = false
        let filtered = input.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A:
                return true
            case 0x00...0x1F, 0x7F...0x9F:
                didStrip = true
                return false
            default:
                return true
            }
        }

        switch didStrip {
        case false:
            return input
        case true:
            logger.info("stripControlCharacters: stripped control characters from input")
            return String(filtered)
        }
    }

    /// Sanitizes a string from untrusted JS context for safe inclusion in logs.
    /// Truncates to `maxLength` and strips control characters to prevent
    /// log injection or oversized log entries.
    static func sanitizeLogString(_ raw: String, maxLength: Int) -> String {
        let truncated: String
        switch raw.count > maxLength {
        case true:
            truncated = String(raw.prefix(maxLength)) + "..."
        case false:
            truncated = raw
        }
        return stripControlCharacters(truncated)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        templateLoaded = true

        // Inject configuration into JS so constants stay synchronized with Swift.
        let configJS = """
        setParleyConfig({
            maxBodyLength: \(PRViewModel.maxBodyLength),
            maxRetryAttempts: 3,
            maxReportFailures: 50,
            cssEscapeMaxLength: \(Self.maxInputBytes)
        });
        """
        webView.evaluateJavaScript(configJS) { _, error in
            if let error {
                Self.logger.warning("Config injection failed: \(error)")
            }
        }

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

        // Circuit breaker: if JS rendering is consistently failing, stop
        // attempting complex renders to avoid thrashing a broken WebKit context.
        guard consecutiveRenderFailures < Self.maxConsecutiveRenderFailures else {
            Self.logger.warning("Circuit breaker open: skipping render after \(self.consecutiveRenderFailures) consecutive failures")
            return
        }

        let markdown = viewModel.markdownContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")

        let threadsJSON = threadsToJSON(viewModel.commentThreads)
        let draftsJSON = draftsToJSON(viewModel.draftComments)

        let js = "renderMarkdown(`\(markdown)`, \(threadsJSON), \(draftsJSON));"
        let jsSnippet = js.prefix(200)
        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let self else { return }
            switch error {
            case .some(let err):
                self.consecutiveRenderFailures += 1
                self.incrementErrorCount()
                Self.logger.error("JS render error (#\(self.jsErrorCount), streak \(self.consecutiveRenderFailures)): \(err) — snippet: \(jsSnippet)…")
            case .none:
                self.consecutiveRenderFailures = 0
            }
        }
    }

    /// Increments `jsErrorCount` with saturating arithmetic to prevent overflow in
    /// long-running sessions. Logs warnings with exponential backoff: first at
    /// `errorWarningInterval`, then at 2x, 4x, 8x, etc.
    private func incrementErrorCount() {
        let (newValue, overflow) = jsErrorCount.addingReportingOverflow(1)
        jsErrorCount = overflow ? Int.max : newValue
        guard jsErrorCount >= nextErrorWarningThreshold else { return }
        Self.logger.warning("JS error count reached \(self.jsErrorCount) — possible systemic issue")
        let (doubled, didOverflow) = nextErrorWarningThreshold.multipliedReportingOverflow(by: 2)
        nextErrorWarningThreshold = didOverflow ? Int.max : doubled
    }

    /// Increments `validationFailureCount` for monitoring. Logs periodically
    /// so operators can detect injection attempts or client bugs.
    private func incrementValidationFailure() {
        let (newValue, overflow) = validationFailureCount.addingReportingOverflow(1)
        validationFailureCount = overflow ? Int.max : newValue
        guard validationFailureCount.isMultiple(of: Self.errorWarningInterval) else { return }
        Self.logger.warning("Validation failure count reached \(self.validationFailureCount) — possible injection or client bug")
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
