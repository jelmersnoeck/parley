---
id: code-review-hardening-r2
status: draft
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
- `Sources/Parley/Views/InspectorPanel.swift` — debounce improvement for onChange
- `Tests/ParleyTests/WebViewCoordinatorTests.swift` — tests for decomposed sanitizedBody helpers

## Behavior

### WebViewCoordinator.swift
1. Add `validationFailureCount` counter (private(set)) incremented by isValidLine,
   parseUUID, and sanitizedBody when they detect problems. Logged every
   `errorWarningInterval` failures.
2. Decompose `sanitizedBody` into: `truncateOversizedInput(_:)`,
   `stripControlCharacters(_:)`, and the existing trim+truncate. Each testable
   independently.
3. JS render circuit breaker: after `maxConsecutiveRenderFailures` (default 5)
   consecutive JS eval errors, stop attempting complex renders and log a
   degraded-mode warning. Reset on successful render.
4. Sanitize `source` and `detail` from JS logError messages: truncate to 500
   chars, strip control characters.
5. `incrementErrorCount` warning frequency uses exponential backoff:
   warn at 1000, 2000, 4000, 8000, etc. instead of every 1000.

### markdown-render.js
6. `postToSwift` retry uses exponential backoff: delays of 100ms, 200ms, 400ms
   before retry attempts (using setTimeout).
7. `saveDraftEdit` catch block distinguishes error types and shows specific
   messages: "Network error" vs "Save failed".
8. Rename `rebuildDraftIndex` to `updateDraftIndex`.
9. `findByDraftId` validates draftId format (UUID regex) before searching.
10. Sanitize error messages in postToSwift catch: truncate JS error toString()
    to 200 chars to prevent sensitive data leakage from WebKit context.

### InspectorPanel.swift
11. Replace isTruncating guard with DispatchQueue.main.async deferral pattern
    to prevent re-entrant onChange issues more robustly.

## Constraints
- No new dependencies.
- All existing tests must pass.
- No changes to DraftComment struct or PRViewModel public API.
- Backoff delays in JS must not block the main thread (use setTimeout).

## Interfaces
```swift
// WebViewCoordinator — new counters and helpers
private(set) var validationFailureCount = 0
private(set) var consecutiveRenderFailures = 0
static let maxConsecutiveRenderFailures = 5

// Decomposed sanitization
static func truncateOversizedInput(_ raw: String) -> String
static func stripControlCharacters(_ input: String) -> String
```

```javascript
// Renamed
function updateDraftIndex() { ... }
```

## Edge Cases
1. Circuit breaker trips after 5 failures, then a successful config injection
   does NOT reset it (only renderMarkdown success resets it).
2. Exponential backoff in incrementErrorCount: at Int.max, no further warnings.
3. postToSwift backoff with setTimeout: if page unloads mid-retry, the timeout
   is silently dropped (acceptable).
4. findByDraftId with non-UUID draftId: logs warning, returns null.
5. saveDraftEdit network error vs generic error: maps TypeError to network error,
   everything else to generic.
