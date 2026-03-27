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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.displayLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text(draft.body)
                    .font(.caption)
                    .lineLimit(3)
            }
            Spacer()
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
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
