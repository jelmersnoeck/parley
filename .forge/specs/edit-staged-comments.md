---
id: edit-staged-comments
status: implemented
---
<!-- Post-review hardening applied: input validation, dedup of empty-body logic,
     O(1) draft lookups, CSS class visibility, extracted helpers.
     Second review pass: structured logging, null-byte sanitization, CSS selector
     escaping, Unicode-safe truncation, DraftEditView extraction, test coverage.
     Third review pass: comprehensive CSS.escape(), JS→Swift error bridging,
     C0/C1 control char stripping, O(maxLen) unicodeTruncate, save error UX,
     known-action allowlist, jsErrorCount metrics, utf8 fast-path in onChange. -->
# Edit staged draft comments before review submission

## Description
Staged (draft) comments are currently immutable after creation. Users need to
refine wording, fix typos, or expand their thoughts as they continue reviewing.
This adds inline editing in both the inspector panel sidebar and the webview's
draft indicators.

## Context
- `Sources/Parley/Views/InspectorPanel.swift` — `DraftCommentRow` view (read-only today)
- `Sources/Parley/ViewModel/PRViewModel.swift` — already has `updateDraftComment(id:body:)` (unused by UI)
- `Sources/Parley/WebView/WebViewCoordinator.swift` — handles JS→Swift messages; needs new `editComment` action
- `Sources/Parley/Resources/markdown-render.js` — renders `draft-indicator` divs (read-only today)
- `Sources/Parley/Resources/styles.css` — draft indicator styles; added `.hidden` utility class
- `Sources/Parley/GitHub/Models.swift` — `DraftComment` struct (unchanged)
- `Tests/ParleyTests/PRViewModelTests.swift` — existing `updateDraft` test + 6 new tests (empty body, non-existent UUID, preserve others, remove non-existent, same body no-op, long body truncation)

## Behavior

### Inspector panel (SwiftUI)
- Each `DraftCommentRow` gains an edit button (pencil icon) next to the existing delete button.
- Clicking the edit button replaces the read-only body text with a `TextEditor` pre-filled with the current body.
- A "Save" button below the editor commits the change via `viewModel.updateDraftComment(id:body:)`.
- A "Cancel" button discards edits and returns to read-only display.
- Pressing Escape while the editor is focused also cancels.
- Saving an empty body is equivalent to deleting the draft (calls `removeDraftComment`).
- After save, the webview re-renders to reflect the updated draft text inline.

### WebView (JS)
- Each `draft-indicator` div gets an "Edit" button (alongside the DRAFT badge).
- Clicking "Edit" replaces the draft indicator with an editing box: a textarea pre-filled with the draft body, a formatting toolbar, "Save" and "Cancel" buttons.
- "Save" posts `{ action: "editComment", id: "<uuid>", body: "<new text>" }` to Swift.
- "Cancel" restores the original draft indicator.
- The coordinator handles the `editComment` message by calling `viewModel.updateDraftComment(id:body:)` and re-rendering content.
- Saving empty body posts `{ action: "removeComment", id: "<uuid>" }` to Swift.

### Coordinator (Swift)
- `WebViewCoordinator.userContentController` handles two new actions:
  - `editComment` — calls `updateDraftComment(id:body:)` + `reloadContent()`
  - `removeComment` — calls `removeDraftComment(id:)` + `reloadContent()`

## Constraints
- Must not change the `DraftComment` struct layout or its `id` generation (UUID).
- Must not alter the submit review flow — `buildReviewRequest` works with whatever the current `draftComments` array contains.
- Must sanitize edited body text through DOMPurify before DOM insertion (same as all other user content).
- Must not break existing staging flow (the `+` button and `stageComment` function).
- Draft IDs passed from JS are UUID strings; the coordinator must parse them with `UUID(uuidString:)`.
- Empty-body-means-delete logic lives exclusively in `PRViewModel.updateDraftComment` — callers must NOT duplicate this check.
- JS validates draft IDs match UUID format (`/^[0-9a-f]{8}-…$/i`) before processing.
- Maximum draft body length enforced on both JS (100,000 chars) and Swift (100,000 chars) sides.
- DOM visibility toggling uses the `.hidden` CSS class, not inline `style.display`.
- `maxBodyLength` is defined once in `PRViewModel` and referenced by coordinator and SwiftUI; JS has its own `MAX_BODY_LENGTH` constant (not yet injected from Swift, but values are synchronized).
- All coordinator message handlers log warnings on invalid input via `os.Logger`.
- CSS attribute selectors use `CSS.escape()` natively (with comprehensive fallback) to prevent selector injection from draft IDs.
- Body text is sanitized (null bytes + C0/C1 control chars stripped, preserving tab/newline/CR) before processing in both JS and Swift.
- JS errors are bridged to Swift via a `logError` message action for production visibility; `console.warn` is not relied upon.
- The coordinator validates incoming actions against a known-action allowlist before processing.
- JS `saveDraftEdit` handles postToSwift failures with user-visible feedback (CSS class + title attribute).
- JS `unicodeTruncate` uses `for..of` iteration for O(maxLen) code-point-aware truncation without `Array.from`.
- The coordinator tracks `jsErrorCount` for monitoring JS rendering failures.
- Successful `editComment` and `removeComment` operations are logged at debug level.
- InspectorPanel `onChange` uses an O(1) `utf8.count` fast-path before the O(n) Character count check.
- UUID parsing is deduplicated into `parseUUID(from:label:)` helper in the coordinator.
- JS `saveDraftEdit` delegates empty-body deletion to Swift (no client-side duplication).
- InspectorPanel enforces `maxBodyLength` via `onChange` truncation in `DraftEditView`.

## Interfaces

### JS → Swift messages

```javascript
// Edit a staged comment
{ action: "editComment", id: "550E8400-E29B-41D4-A716-446655440000", body: "updated text" }

// Remove a staged comment from webview
{ action: "removeComment", id: "550E8400-E29B-41D4-A716-446655440000" }
```

### Swift coordinator handler additions

```swift
case "editComment":
    guard let uuid = Self.parseUUID(from: body, label: "editComment") else { return }
    guard let newBody = body["body"] as? String else {
        Self.logger.warning("editComment: missing 'body' field")
        return
    }
    let sanitized = Self.sanitizedBody(newBody)
    viewModel.updateDraftComment(id: uuid, body: sanitized)
    reloadContent()

case "removeComment":
    guard let uuid = Self.parseUUID(from: body, label: "removeComment") else { return }
    viewModel.removeDraftComment(id: uuid)
    reloadContent()
```

### Swift model — `updateDraftComment` (single source of truth for empty-body deletion)

```swift
func updateDraftComment(id: UUID, body: String) {
    guard let index = draftComments.firstIndex(where: { $0.id == id }) else { return }
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        draftComments.remove(at: index)
    } else {
        draftComments[index].body = body
    }
}
```

### SwiftUI inspector — `DraftCommentRow` state

```swift
struct DraftCommentRow: View {
    let draft: DraftComment
    let onTap: () -> Void
    let onRemove: () -> Void
    let onSave: (String) -> Void  // new

    @State private var isEditing = false
    @State private var editText = ""
    // ...
}
```

### JS functions (new)

```javascript
function editDraftComment(draftId)       // swap indicator -> edit box (validates UUID + context)
function saveDraftEdit(draftId)          // post editComment to Swift (validates, sanitizes, Unicode-safe truncation, error UX)
function cancelDraftEdit(draftId)        // restore indicator (UUID-validated, CSS-escaped selectors)
function removeDraftFromWebView(draftId) // post removeComment to Swift (validates UUID, reports to Swift)
function createEditBox(draftId, body)    // builds the edit box DOM subtree (sanitizes body)
function createEditActions(draftId)      // builds Save/Cancel button wrap
function rebuildDraftIndex()             // rebuilds draftCommentsById Map (fingerprint-gated, null-byte separator)
function isValidUUID(str)                // UUID format validation
function findDraftById(draftId)          // O(1) lookup via draftCommentsById
function cssEscape(str)                  // CSS.escape() native with comprehensive fallback
function sanitizeBodyText(str)           // strips C0/C1 control chars from body text
function unicodeTruncate(str, maxLen)    // O(maxLen) code-point-aware string truncation
function reportToSwift(source, detail)   // bridges JS warnings/errors to Swift os.Logger
```

## Edge Cases

1. **Empty body on save (inspector):** Treated as deletion — calls `removeDraftComment`,
   draft disappears from both inspector list and webview.

2. **Empty body on save (webview):** Posts `removeComment` action. Coordinator deletes
   the draft and re-renders. The edit box and draft indicator both disappear.

3. **Edit then cancel:** Original body text is preserved. No message sent to Swift.
   DOM returns to the original draft indicator state.

4. **Multiple drafts on same line:** Each has its own UUID and independent edit state.
   Editing one does not affect others.

5. **Edit in inspector while webview edit box is open for same draft:** The webview
   re-renders on save (inspector calls `reloadContent`), which destroys any in-flight
   webview edit box. This is acceptable — the inspector is the authoritative editor.

6. **Rapid double-click on edit button (JS):** `editDraftComment` checks if an edit box
   already exists for that draft ID before creating another.

7. **Non-existent UUID from JS:** `updateDraftComment` silently no-ops (existing
   behavior of the `guard let index` check). No crash.
