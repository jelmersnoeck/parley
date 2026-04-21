import Testing
import Foundation
@testable import Parley

@Suite("WebViewCoordinator")
struct WebViewCoordinatorTests {
    // MARK: - sanitizedBody

    @Test("passes through clean text")
    func sanitizedBodyCleanText() {
        let result = WebViewCoordinator.sanitizedBody("Hello, Greendale!")
        #expect(result == "Hello, Greendale!")
    }

    @Test("strips C0 control characters but keeps tab and newline")
    func sanitizedBodyKeepsTabNewline() {
        let input = "Troy\t\nBarnes\u{01}\u{02}"
        let result = WebViewCoordinator.sanitizedBody(input)
        #expect(result == "Troy\t\nBarnes")
    }

    @Test("strips DEL and C1 control characters")
    func sanitizedBodyStripsDELC1() {
        let input = "Dean\u{7F}Pelton\u{80}\u{9F}"
        let result = WebViewCoordinator.sanitizedBody(input)
        #expect(result == "DeanPelton")
    }

    @Test("strips CR (0x0D)")
    func sanitizedBodyStripsCR() {
        let input = "line1\r\nline2"
        let result = WebViewCoordinator.sanitizedBody(input)
        #expect(result == "line1\nline2")
    }

    @Test("trims leading and trailing whitespace")
    func sanitizedBodyTrims() {
        let result = WebViewCoordinator.sanitizedBody("  cool cool cool  \n ")
        #expect(result == "cool cool cool")
    }

    @Test("truncates to maxBodyLength")
    func sanitizedBodyTruncates() {
        let long = String(repeating: "A", count: PRViewModel.maxBodyLength + 100)
        let result = WebViewCoordinator.sanitizedBody(long)
        #expect(result.count == PRViewModel.maxBodyLength)
    }

    @Test("handles oversized input (beyond maxInputBytes) without recursion")
    func sanitizedBodyLargeInputNoRecursion() {
        // 2MB of ASCII — should be truncated iteratively, not recursively
        let big = String(repeating: "B", count: 2_000_000)
        let result = WebViewCoordinator.sanitizedBody(big)
        #expect(result.count <= PRViewModel.maxBodyLength)
    }

    @Test("returns empty for whitespace-only input")
    func sanitizedBodyWhitespaceOnly() {
        let result = WebViewCoordinator.sanitizedBody("   \n\t  ")
        #expect(result.isEmpty)
    }

    // MARK: - Constants are accessible

    @Test("maxLineNumber is a positive value")
    func maxLineNumberPositive() {
        #expect(WebViewCoordinator.maxLineNumber > 0)
    }

    @Test("maxInputBytes is a positive value")
    func maxInputBytesPositive() {
        #expect(WebViewCoordinator.maxInputBytes > 0)
    }

    @Test("errorWarningInterval is a positive value")
    func errorWarningIntervalPositive() {
        #expect(WebViewCoordinator.errorWarningInterval > 0)
    }

    // MARK: - truncateOversizedInput

    @Test("truncateOversizedInput passes through small strings unchanged")
    func truncateOversizedInputSmall() {
        let input = "Streets ahead"
        #expect(WebViewCoordinator.truncateOversizedInput(input) == input)
    }

    @Test("truncateOversizedInput chops strings exceeding maxInputBytes")
    func truncateOversizedInputLarge() {
        let big = String(repeating: "X", count: WebViewCoordinator.maxInputBytes + 500)
        let result = WebViewCoordinator.truncateOversizedInput(big)
        #expect(result.utf8.count <= WebViewCoordinator.maxInputBytes)
    }

    // MARK: - stripControlCharacters

    @Test("stripControlCharacters removes C0 but keeps tab and newline")
    func stripControlCharsKeepsTabNewline() {
        let input = "Annie\t\nEdison\u{01}\u{08}"
        #expect(WebViewCoordinator.stripControlCharacters(input) == "Annie\t\nEdison")
    }

    @Test("stripControlCharacters removes DEL and C1 range")
    func stripControlCharsRemovesDELC1() {
        let input = "Jeff\u{7F}Winger\u{80}\u{9F}"
        #expect(WebViewCoordinator.stripControlCharacters(input) == "JeffWinger")
    }

    @Test("stripControlCharacters returns clean input unchanged")
    func stripControlCharsCleanInput() {
        let input = "Pop pop!"
        #expect(WebViewCoordinator.stripControlCharacters(input) == input)
    }

    @Test("stripControlCharacters strips CR 0x0D")
    func stripControlCharsStripsCR() {
        let input = "cool\r\ncool\r\ncool"
        #expect(WebViewCoordinator.stripControlCharacters(input) == "cool\ncool\ncool")
    }

    // MARK: - sanitizeLogString

    @Test("sanitizeLogString truncates long strings")
    func sanitizeLogStringTruncates() {
        let long = String(repeating: "A", count: 1000)
        let result = WebViewCoordinator.sanitizeLogString(long, maxLength: 500)
        #expect(result.count <= 503) // 500 + "..."
    }

    @Test("sanitizeLogString strips control characters")
    func sanitizeLogStringStripsControl() {
        let input = "error\u{01}\u{02}message"
        let result = WebViewCoordinator.sanitizeLogString(input, maxLength: 500)
        #expect(!result.contains("\u{01}"))
        #expect(result.contains("error"))
        #expect(result.contains("message"))
    }

    @Test("sanitizeLogString passes through clean short strings")
    func sanitizeLogStringCleanShort() {
        let input = "all good"
        #expect(WebViewCoordinator.sanitizeLogString(input, maxLength: 500) == input)
    }

    // MARK: - maxConsecutiveRenderFailures constant

    @Test("maxConsecutiveRenderFailures is positive")
    func maxConsecutiveRenderFailuresPositive() {
        #expect(WebViewCoordinator.maxConsecutiveRenderFailures > 0)
    }

    // MARK: - Nested structs

    @Test("Limits struct exposes expected values")
    func limitsValues() {
        #expect(WebViewCoordinator.Limits.maxLineNumber == 1_000_000)
        #expect(WebViewCoordinator.Limits.maxInputBytes == 1_000_000)
        #expect(WebViewCoordinator.Limits.maxLogStringLength == 500)
        #expect(WebViewCoordinator.Limits.maxConsecutiveRenderFailures == 5)
    }

    @Test("Thresholds struct exposes expected values")
    func thresholdsValues() {
        #expect(WebViewCoordinator.Thresholds.errorWarningInterval == 1_000)
        #expect(WebViewCoordinator.Thresholds.maxErrorWarningThreshold == 1_000_000)
        #expect(WebViewCoordinator.Thresholds.circuitBreakerCooldown == 30)
    }

    @Test("backward-compat static accessors delegate to nested structs")
    func backwardCompatAccessors() {
        #expect(WebViewCoordinator.maxLineNumber == WebViewCoordinator.Limits.maxLineNumber)
        #expect(WebViewCoordinator.maxInputBytes == WebViewCoordinator.Limits.maxInputBytes)
        #expect(WebViewCoordinator.errorWarningInterval == WebViewCoordinator.Thresholds.errorWarningInterval)
        #expect(WebViewCoordinator.maxConsecutiveRenderFailures == WebViewCoordinator.Limits.maxConsecutiveRenderFailures)
    }

    // MARK: - HealthMetrics

    @Test("healthMetrics reports initial zeroed state")
    @MainActor func healthMetricsInitial() {
        let vm = PRViewModel()
        let coord = WebViewCoordinator(viewModel: vm)
        let m = coord.healthMetrics
        #expect(m.jsErrorCount == 0)
        #expect(m.validationFailureCount == 0)
        #expect(m.consecutiveRenderFailures == 0)
        #expect(m.circuitBreakerOpen == false)
    }

    // MARK: - DraftBodyEnforcer

    @Test("DraftBodyEnforcer.truncated returns nil for short strings")
    func enforcerShort() {
        #expect(DraftBodyEnforcer.truncated("Greendale") == nil)
    }

    @Test("DraftBodyEnforcer.truncated truncates long strings")
    func enforcerLong() {
        let long = String(repeating: "X", count: PRViewModel.maxBodyLength + 100)
        let result = DraftBodyEnforcer.truncated(long)
        #expect(result != nil)
        #expect(result!.count == PRViewModel.maxBodyLength)
    }

    @Test("DraftBodyEnforcer.enforced passes through short strings")
    func enforcedShort() {
        let input = "Human Being mascot"
        #expect(DraftBodyEnforcer.enforced(input) == input)
    }

    @Test("DraftBodyEnforcer.enforced clamps long strings")
    func enforcedLong() {
        let long = String(repeating: "Z", count: PRViewModel.maxBodyLength + 50)
        #expect(DraftBodyEnforcer.enforced(long).count == PRViewModel.maxBodyLength)
    }
}
