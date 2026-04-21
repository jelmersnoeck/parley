import Foundation
import os
import WebKit

final class WebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let viewModel: PRViewModel
    weak var webView: WKWebView?
    private var templateLoaded = false
    private var pendingContentLoad = false

    // MARK: - Organized constants

    /// Grouping of hard limits: sizes, counts, ceilings.
    struct Limits {
        /// Files beyond 1M lines are implausible; anything higher is likely injection.
        static let maxLineNumber = 1_000_000
        /// Max UTF-8 bytes to process through Unicode scalar filtering.
        static let maxInputBytes = 1_000_000
        /// Max length for log strings from untrusted JS context.
        static let maxLogStringLength = 500
        /// Consecutive JS render failures before entering degraded mode.
        static let maxConsecutiveRenderFailures = 5
    }

    /// Grouping of threshold/timing values for backoff and recovery.
    struct Thresholds {
        /// Initial error count for health-monitoring warnings.
        static let errorWarningInterval = 1_000
        /// Cap for exponential backoff — warnings fire at least every 1M errors.
        static let maxErrorWarningThreshold = 1_000_000
        /// Seconds before the circuit breaker auto-resets for a retry.
        static let circuitBreakerCooldown: TimeInterval = 30
    }

    // Backward-compatible accessors for tests / external callers
    static var maxLineNumber: Int { Limits.maxLineNumber }
    static var maxInputBytes: Int { Limits.maxInputBytes }
    static var errorWarningInterval: Int { Thresholds.errorWarningInterval }
    static var maxConsecutiveRenderFailures: Int { Limits.maxConsecutiveRenderFailures }

    // MARK: - Metrics

    /// Snapshot of coordinator health for monitoring systems.
    struct HealthMetrics {
        let jsErrorCount: Int
        let validationFailureCount: Int
        let consecutiveRenderFailures: Int
        let circuitBreakerOpen: Bool
    }

    /// Tracks JS error count for production monitoring.
    private(set) var jsErrorCount = 0

    /// Tracks validation failures (bad UUIDs, out-of-range lines, sanitization hits).
    private(set) var validationFailureCount = 0

    /// Consecutive JS render eval failures. When this hits the limit,
    /// complex rendering is skipped to avoid thrashing a broken WebKit context.
    private(set) var consecutiveRenderFailures = 0

    /// When the circuit breaker opened; nil = closed.
    private var circuitBreakerOpenedAt: Date?

    var healthMetrics: HealthMetrics {
        HealthMetrics(
            jsErrorCount: jsErrorCount,
            validationFailureCount: validationFailureCount,
            consecutiveRenderFailures: consecutiveRenderFailures,
            circuitBreakerOpen: consecutiveRenderFailures >= Limits.maxConsecutiveRenderFailures
        )
    }

    /// Security control: only these actions are processed from JS messages.
    private static let knownActions: Set<String> = [
        "addComment", "submitReply", "editComment", "removeComment",
        "expandThread", "collapseThread", "logError",
    ]

    /// Next error count threshold for warning. Doubles after each warning,
    /// capped at `maxErrorWarningThreshold`.
    private var nextErrorWarningThreshold = Thresholds.errorWarningInterval

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.parley",
        category: "WebViewCoordinator"
    )

    init(viewModel: PRViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
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
                handleAddComment(body)
            case "submitReply":
                await handleSubmitReply(body)
            case "editComment":
                handleEditComment(body)
            case "removeComment":
                handleRemoveComment(body)
            case "logError":
                handleLogError(body)
            case "expandThread", "collapseThread":
                break
            default:
                break
            }
        }
    }

    // MARK: - Message handlers

    @MainActor
    private func handleAddComment(_ body: [String: Any]) {
        guard let line = body["line"] as? Int,
              isValidLine(line, label: "addComment"),
              let commentBody = body["body"] as? String,
              let validated = Self.validatedBody(commentBody) else {
            Self.logger.warning("addComment: invalid payload — line or body missing/empty")
            return
        }
        let startLine = body["startLine"] as? Int
        let path = viewModel.prMetadata?.markdownFilePath ?? ""
        viewModel.addDraftComment(line: line, startLine: startLine, body: validated, path: path)
        reloadContent()
    }

    @MainActor
    private func handleSubmitReply(_ body: [String: Any]) async {
        guard let commentId = body["commentId"] as? Int,
              let replyBody = body["body"] as? String,
              let validated = Self.validatedBody(replyBody) else {
            Self.logger.warning("submitReply: invalid payload — commentId or body missing/empty")
            return
        }
        await viewModel.replyToThread(commentId: commentId, body: validated)
    }

    @MainActor
    private func handleEditComment(_ body: [String: Any]) {
        guard let uuid = parseUUID(from: body, label: "editComment") else { return }
        guard let newBody = body["body"] as? String else {
            Self.logger.warning("editComment: missing 'body' field")
            return
        }
        let sanitized = Self.sanitizedBody(newBody)
        viewModel.updateDraftComment(id: uuid, body: sanitized)
        Self.logger.debug("editComment: updated draft \(uuid)")
        reloadContent()
    }

    @MainActor
    private func handleRemoveComment(_ body: [String: Any]) {
        guard let uuid = parseUUID(from: body, label: "removeComment") else { return }
        viewModel.removeDraftComment(id: uuid)
        Self.logger.debug("removeComment: removed draft \(uuid)")
        reloadContent()
    }

    private func handleLogError(_ body: [String: Any]) {
        let rawSource = body["source"] as? String ?? "unknown"
        let rawDetail = body["detail"] as? String ?? "(no detail)"
        let source = Self.sanitizeLogString(rawSource, maxLength: Limits.maxLogStringLength)
        let detail = Self.sanitizeLogString(rawDetail, maxLength: Limits.maxLogStringLength)
        incrementErrorCount()
        Self.logger.error("JS error (#\(self.jsErrorCount)) [\(source)]: \(detail)")
    }

    // MARK: - Input validation

    private func isValidLine(_ line: Int, label: String) -> Bool {
        guard line > 0, line <= Limits.maxLineNumber else {
            Self.logger.warning("\(label): line \(line) out of valid range 1...\(Limits.maxLineNumber)")
            incrementValidationFailure()
            return false
        }
        return true
    }

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

    private static func validatedBody(_ raw: String) -> String? {
        let result = sanitizedBody(raw)
        guard !result.isEmpty else { return nil }
        return result
    }

    /// Sanitizes and truncates a body string.
    /// Pipeline: oversized truncation -> control char stripping -> trim -> length truncation.
    static func sanitizedBody(_ raw: String) -> String {
        let bounded = truncateOversizedInput(raw)
        let stripped = stripControlCharacters(bounded)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(PRViewModel.maxBodyLength))
    }

    static func truncateOversizedInput(_ raw: String) -> String {
        guard raw.utf8.count > Limits.maxInputBytes else { return raw }
        logger.warning("truncateOversizedInput: input too large (\(raw.utf8.count) bytes), truncating")
        return String(raw.prefix(Limits.maxInputBytes))
    }

    /// Single-pass filter over unicodeScalars: strips null bytes + C0/C1 control
    /// characters (preserving tab 0x09 and newline 0x0A).
    ///
    /// Fast path: scans scalars first with `contains(where:)` and returns the
    /// original string immediately when no stripping is needed, avoiding
    /// allocation of a filtered collection.
    static func stripControlCharacters(_ input: String) -> String {
        let needsStripping = input.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x09, 0x0A:
                return false
            case 0x00...0x1F, 0x7F...0x9F:
                return true
            default:
                return false
            }
        }
        guard needsStripping else { return input }

        logger.info("stripControlCharacters: stripped control characters from input")
        let filtered = input.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A:
                return true
            case 0x00...0x1F, 0x7F...0x9F:
                return false
            default:
                return true
            }
        }
        return String(filtered)
    }

    /// Sanitizes a string from untrusted JS context for safe inclusion in logs.
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

        let configJS = """
        setParleyConfig({
            maxBodyLength: \(PRViewModel.maxBodyLength),
            maxRetryAttempts: 3,
            maxReportFailures: 50,
            cssEscapeMaxLength: \(Limits.maxInputBytes)
        });
        """
        webView.evaluateJavaScript(configJS) { _, error in
            if let error {
                Self.logger.warning("Config injection failed: \(error)")
            }
        }

        guard pendingContentLoad else { return }
        pendingContentLoad = false
        Task { @MainActor in
            loadContent(in: webView)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        switch url.scheme {
        case "file", "about":
            return .allow
        default:
            guard navigationAction.navigationType == .linkActivated else { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
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
        guard templateLoaded else {
            pendingContentLoad = true
            return
        }

        // Circuit breaker with time-based auto-reset
        if consecutiveRenderFailures >= Limits.maxConsecutiveRenderFailures {
            if let openedAt = circuitBreakerOpenedAt,
               Date().timeIntervalSince(openedAt) >= Thresholds.circuitBreakerCooldown {
                Self.logger.info("Circuit breaker cooldown elapsed — attempting recovery render")
                consecutiveRenderFailures = 0
                circuitBreakerOpenedAt = nil
            } else {
                Self.logger.warning("Circuit breaker open: skipping render after \(self.consecutiveRenderFailures) consecutive failures")
                return
            }
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
                if self.consecutiveRenderFailures >= Limits.maxConsecutiveRenderFailures {
                    self.circuitBreakerOpenedAt = Date()
                }
                self.incrementErrorCount()
                Self.logger.error("JS render error (#\(self.jsErrorCount), streak \(self.consecutiveRenderFailures)): \(err) — snippet: \(jsSnippet)…")
            case .none:
                self.consecutiveRenderFailures = 0
                self.circuitBreakerOpenedAt = nil
            }
        }
    }

    // MARK: - Error counting

    /// Increments `jsErrorCount` with saturating arithmetic. Logs warnings with
    /// exponential backoff capped at `maxErrorWarningThreshold` to avoid silent gaps.
    private func incrementErrorCount() {
        let (newValue, overflow) = jsErrorCount.addingReportingOverflow(1)
        jsErrorCount = overflow ? Int.max : newValue
        guard jsErrorCount >= nextErrorWarningThreshold else { return }
        Self.logger.warning("JS error count reached \(self.jsErrorCount) — possible systemic issue")
        let (doubled, didOverflow) = nextErrorWarningThreshold.multipliedReportingOverflow(by: 2)
        switch didOverflow || doubled > Thresholds.maxErrorWarningThreshold {
        case true:
            nextErrorWarningThreshold = Thresholds.maxErrorWarningThreshold
        case false:
            nextErrorWarningThreshold = doubled
        }
    }

    private func incrementValidationFailure() {
        let (newValue, overflow) = validationFailureCount.addingReportingOverflow(1)
        validationFailureCount = overflow ? Int.max : newValue
        guard validationFailureCount.isMultiple(of: Thresholds.errorWarningInterval) else { return }
        Self.logger.warning("Validation failure count reached \(self.validationFailureCount) — possible injection or client bug")
    }

    // MARK: - JSON helpers

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
