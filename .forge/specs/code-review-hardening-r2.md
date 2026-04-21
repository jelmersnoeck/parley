---
id: code-review-hardening-r2
status: implemented
---
# Second-pass hardening from code review findings

## Description
Address remaining code review findings not covered by round one. Focuses on:
metrics/monitoring for validation failures, JS render circuit breaker,
exponential backoff in retry paths, error message sanitization, decomposing
sanitizedBody, and minor naming/documentation improvements.

## Context
- `Sources/Parley/WebView/WebViewCoordinator.swift` — validation metrics, sanitizedBody decomposition, circuit breaker, log sanitization, error count backoff
- `Sources/Parley/Resources/markdown-render.js` — postToSwift backoff, error type differentiation in saveDraftEdit, rename rebuildDraftIndex, draftId validation, error message sanitization
- `Sources/Parley/Views/InspectorPanel.swift` — debounce improvement for onChange (truncationToken pattern)
- `Sources/Parley/ViewModel/PRViewModel.swift` — unchanged (pre-existing changes in working tree from prior session)
- `Tests/ParleyTests/WebViewCoordinatorTests.swift` — 21 tests for decomposed helpers and constants
- `Tests/ParleyTests/PRViewModelTests.swift` — unchanged (pre-existing)

## Behavior

### WebViewCoordinator.swift
1. `validationFailureCount` counter incremented by `isValidLine` and `parseUUID`
   on failure. Logged every `errorWarningInterval` (1000) failures.
2. `sanitizedBody` decomposed into pipeline: `truncateOversizedInput(_:)` →
   `stripControlCharacters(_:)` → trim → prefix. Each function is `static`
   and independently testable.
3. `sanitizeLogString(_:maxLength:)` truncates to maxLength + "..." and strips
   control characters. Used for JS logError source/detail fields.
4. Circuit breaker: `consecutiveRenderFailures` tracks streak. At
   `maxConsecutiveRenderFailures` (5), `loadContent` skips JS eval and logs
   warning. Resets to 0 on successful render.
5. `incrementErrorCount` warning uses exponential backoff via
   `nextErrorWarningThreshold` (starts at 1000, doubles each time).
6. `isValidLine` and `parseUUID` changed from `static` to instance methods
   to access `incrementValidationFailure()`.

### markdown-render.js
7. `postToSwift` retry uses exponential backoff via setTimeout: 100ms * 2^attempt.
   Error toString() truncated to 200 chars before logging.
8. `saveDraftEdit` catch distinguishes TypeError (bridge unavailable) vs generic
   error, passes specific user message to `showSaveError(draftId, message)`.
9. `showSaveError` accepts optional `message` parameter for context-specific
   tooltip text.
10. `rebuildDraftIndex` renamed to `updateDraftIndex`.
11. `findByDraftId` validates draftId with `isValidUUID()` before DOM search.
12. `unicodeTruncate` comment expanded explaining immutable string optimization.

### InspectorPanel.swift
13. `DraftEditView` replaces `isTruncating` boolean guard with `truncationToken`
    Int counter. Extracted `truncateIfNeeded(_:)` method. Token-based approach
    is immune to stale boolean state from coalesced SwiftUI events.

## Constraints
- No new dependencies.
- All 50 existing tests pass.
- No changes to DraftComment struct or PRViewModel public API.
- Backoff delays in JS use setTimeout (non-blocking).

## Interfaces
```swift
// WebViewCoordinator — new counters and helpers
private(set) var validationFailureCount = 0
private(set) var consecutiveRenderFailures = 0
static let maxConsecutiveRenderFailures = 5
static func truncateOversizedInput(_ raw: String) -> String
static func stripControlCharacters(_ input: String) -> String
static func sanitizeLogString(_ raw: String, maxLength: Int) -> String
```

```javascript
// Renamed: rebuildDraftIndex -> updateDraftIndex
function updateDraftIndex() { ... }

// Updated: showSaveError accepts message
function showSaveError(draftId, message) { ... }
```

## Edge Cases
1. Circuit breaker trips after 5 failures; only `loadContent` success resets it.
   Config injection does NOT reset it.
2. Exponential backoff in incrementErrorCount: at Int.max nextErrorWarningThreshold,
   no further warnings emitted.
3. postToSwift backoff with setTimeout: if page unloads mid-retry, the timeout
   is silently dropped (acceptable).
4. findByDraftId with non-UUID draftId: reports to Swift, returns null.
5. saveDraftEdit TypeError → "Connection to app lost" message; other errors →
   "Save failed" message.
6. sanitizeLogString on clean short input: passes through unchanged.
7. truncationToken overflow: Int wraps at 2^63, effectively infinite for UI use.
