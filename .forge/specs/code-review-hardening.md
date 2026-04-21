---
id: code-review-hardening
status: implemented
---
# Harden draft editing based on code review findings

## Description
Address code review findings across WebViewCoordinator.swift,
markdown-render.js, and InspectorPanel.swift. Several items were already
handled by existing code (recursion guard, CSS.escape fallback, overflow
bounds, single-pass truncation). Remaining items required logging improvements,
structural validation reordering, sanitization monitoring, save-error UX
with retry, paste-event defense, and a second round of hardening focused on
error-handling robustness, DOM lookup safety, and documentation.

## Context
- `Sources/Parley/WebView/WebViewCoordinator.swift` — message handling, sanitization, error tracking, JS eval logging
- `Sources/Parley/Resources/markdown-render.js` — draft editing, DOM manipulation, error bridging, cssEscape
- `Sources/Parley/Views/InspectorPanel.swift` — DraftEditView with TextEditor
- `Tests/ParleyTests/PRViewModelTests.swift` — existing model tests (unchanged, all pass)

## Behavior

### WebViewCoordinator.swift
1. Malformed message log: logs only `type(of:)` for non-dict payloads, and only
   key names for dicts missing an action. Never logs raw content.
2. `jsErrorCount` exposed as `private(set) var` for external monitoring.
3. Structure validation split: dict check first, then action extraction, then
   allowlist. Non-dict payloads are rejected before any field parsing.
4. `sanitizedBody` single-pass filter: combines control-character detection and
   stripping in one `unicodeScalars.filter` pass. When no characters are stripped
   (strippedCount == 0), returns original string without allocation.
5. `sanitizedBody` logs stripped character count via `logger.info` when
   sanitization actually removes characters.
6. JS evaluation errors now include a truncated JS snippet (first 200 chars)
   in the log message for debugging production rendering issues.
7. `incrementErrorCount()` bounds `jsErrorCount` at `Int.max` and logs a
   warning every 1000 errors as a health signal.

### markdown-render.js
8. `postToSwift` error handling: replaced boolean recursion guard with a
   counter-based approach (`_postToSwiftErrorAttempts` capped at 3). Failed
   error reports are logged to console with attempt count. Counter resets on
   successful `postMessage`.
9. `rebuildDraftIndex` fingerprint uses `|` separator instead of `\0`.
10. `saveDraftEdit` error state shows a "Retry" button (via `showSaveError`)
    that re-invokes `saveDraftEdit`. `clearSaveError` removes the retry button
    and error styling on success or user input.
11. `editDraftComment` validates `cssEscape` result is non-empty before using
    in DOM queries.
12. `sanitizeBodyText` regex documented with explicit character range comments
    mirroring Swift sanitizedBody ranges.
13. `cssEscape` fallback documented with full character class table per
    CSSWG serialize-an-identifier spec.
14. New `findByDraftId(className, draftId)` helper uses `dataset.draftId`
    comparison instead of CSS selector construction — avoids cssEscape edge
    cases entirely. Used by `editDraftComment`, `cancelDraftEdit`, and
    `clearSaveError`.
15. `createEditBox` textarea gets an `input` event listener that calls
    `clearSaveError` on keystroke, preventing stale error indicators.

### InspectorPanel.swift
16. `.onSubmit` calls `enforceMaxLength()` for focus-loss truncation.
    Save button also calls `enforceMaxLength()` before `onSave()`.
17. Expanded inline comment on utf8.count fast-path documenting the
    multi-byte behavior and why false-positives are harmless.

## Constraints
- No new dependencies added.
- DraftComment struct and PRViewModel public API unchanged (except jsErrorCount
  visibility on coordinator).
- All 22 existing tests pass.
- Logging uses os.Logger (Swift) and reportToSwift (JS) exclusively.

## Interfaces
```swift
// WebViewCoordinator — jsErrorCount now readable externally
private(set) var jsErrorCount = 0
```

```javascript
// JS helpers for save error UX
function showSaveError(draftId)   // adds .save-error CSS + retry button
function clearSaveError(draftId)  // removes error state + retry button

// DOM lookup without CSS selector construction
function findByDraftId(className, draftId)  // dataset.draftId comparison
```

## Edge Cases
1. Malformed message body that is not a dictionary — logs type, rejects early.
2. Clean strings through sanitizedBody — no allocation penalty (single pass, strippedCount == 0).
3. Draft fingerprint with pipe chars in IDs — impossible (UUID format).
4. Paste of oversized text into TextEditor — caught on submit/save via enforceMaxLength.
5. saveDraftEdit retry after error — clearSaveError removes stale state, retries save.
6. cssEscape returning empty string — logged and rejected, no DOM query attempted.
7. sanitizeBodyText stripping chars — count reported to Swift for monitoring.
8. postToSwift error reporting itself fails — capped at 3 attempts, logs to console as fallback.
9. JS eval failure — log includes truncated JS snippet for debugging.
10. jsErrorCount in long sessions — bounded at Int.max, health warning every 1000.
