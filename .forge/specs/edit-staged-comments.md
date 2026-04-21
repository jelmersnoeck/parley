---
id: edit-staged-comments
status: implemented
---
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
- `Sources/Parley/Resources/styles.css` — draft indicator styles
- `Sources/Parley/GitHub/Models.swift` — `DraftComment` struct (unchanged)
- `Tests/ParleyTests/PRViewModelTests.swift` — existing `updateDraft` test + 4 new tests

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
    guard let idString = body["id"] as? String,
          let uuid = UUID(uuidString: idString),
          let newBody = body["body"] as? String else { return }
    if newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        viewModel.removeDraftComment(id: uuid)
    } else {
        viewModel.updateDraftComment(id: uuid, body: newBody)
    }
    reloadContent()

case "removeComment":
    guard let idString = body["id"] as? String,
          let uuid = UUID(uuidString: idString) else { return }
    viewModel.removeDraftComment(id: uuid)
    reloadContent()
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
function editDraftComment(draftId)    // swap indicator → edit box
function saveDraftEdit(draftId)       // post editComment to Swift
function cancelDraftEdit(draftId)     // restore indicator
function removeDraftFromWebView(draftId) // post removeComment to Swift
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
