import SwiftUI

struct InspectorPanel: View {
    @Bindable var viewModel: PRViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pr = viewModel.prMetadata {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        PRStateBadge(state: pr.state)
                        Text("by \(pr.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 8)

                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Draft Comments")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(viewModel.draftComments.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.draftComments.isEmpty {
                    Text("No draft comments yet. Click + next to a line in the document to add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.draftComments) { draft in
                        DraftCommentRow(draft: draft, onTap: {
                            viewModel.scrollTarget = draft.line
                        }, onRemove: {
                            viewModel.removeDraftComment(id: draft.id)
                        }, onSave: { newBody in
                            viewModel.updateDraftComment(id: draft.id, body: newBody)
                        })
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Review Summary")
                    .font(.subheadline.weight(.semibold))

                TextEditor(text: $viewModel.reviewBody)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 200)
                    .padding(4)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 300)
        .background(.background)
    }
}

struct DraftCommentRow: View {
    let draft: DraftComment
    let onTap: () -> Void
    let onRemove: () -> Void
    let onSave: (String) -> Void

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(draft.displayLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Button {
                    editText = draft.body
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                DraftEditView(
                    editText: $editText,
                    onSave: {
                        onSave(editText)
                        isEditing = false
                    },
                    onCancel: {
                        isEditing = false
                    }
                )
            } else {
                Text(draft.body)
                    .font(.caption)
                    .lineLimit(3)
            }
        }
        .padding(8)
        .background(.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Text length enforcement

/// Pure-logic utility for draft body length enforcement.
/// Separated from DraftEditView so truncation/validation logic is testable
/// without SwiftUI dependencies.
enum DraftBodyEnforcer {
    /// Truncates `value` to `PRViewModel.maxBodyLength` Characters if it exceeds
    /// the limit. Returns nil when no truncation is needed.
    ///
    /// Fast-path: `utf8.count` is O(1) on Swift strings. Since every Character
    /// encodes to >= 1 UTF-8 byte, `utf8.count >= count`. When UTF-8 length is
    /// within limit, Character count must be too — skip the O(n) `count` check.
    static func truncated(_ value: String) -> String? {
        guard value.utf8.count > PRViewModel.maxBodyLength else { return nil }
        guard value.count > PRViewModel.maxBodyLength else { return nil }
        return String(value.prefix(PRViewModel.maxBodyLength))
    }

    /// Enforces max length on a binding value, returning the clamped string.
    static func enforced(_ value: String) -> String {
        truncated(value) ?? value
    }
}

/// Extracted editing UI with length enforcement.
private struct DraftEditView: View {
    @Binding var editText: String
    let onSave: () -> Void
    let onCancel: () -> Void

    /// Debounce token: incremented on each programmatic truncation to let
    /// onChange ignore the echo. More robust than a boolean guard — even if
    /// SwiftUI coalesces or reorders change events, stale tokens are harmless.
    @State private var truncationToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $editText)
                .font(.caption)
                .frame(minHeight: 40, maxHeight: 120)
                .padding(4)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .onChange(of: editText) { _, newValue in
                    guard let truncated = DraftBodyEnforcer.truncated(newValue) else { return }
                    truncationToken += 1
                    editText = truncated
                }
                // Belt-and-suspenders: catch paste events that bypass onChange
                // by re-validating when the editor loses focus.
                .onSubmit {
                    editText = DraftBodyEnforcer.enforced(editText)
                }

            HStack(spacing: 8) {
                Button("Save") {
                    editText = DraftBodyEnforcer.enforced(editText)
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

struct PRStateBadge: View {
    let state: PRState

    var body: some View {
        Text(state.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch state {
        case .open: .green
        case .closed: .red
        case .merged: .purple
        }
    }
}
