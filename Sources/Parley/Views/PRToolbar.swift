import SwiftUI

struct PRToolbar: View {
    @Bindable var viewModel: PRViewModel

    var body: some View {
        HStack(spacing: 12) {
            // URL input with history dropdown
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste GitHub PR URL...", text: $viewModel.urlInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.loadPR() }
                    }

                // History menu
                if !viewModel.history.entries.isEmpty {
                    Menu {
                        ForEach(viewModel.history.entries) { entry in
                            Button {
                                viewModel.urlInput = entry.url
                                Task { await viewModel.loadPR() }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.title)
                                    Text("\(entry.repo) #\(entry.number)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider()
                        Button("Clear History", role: .destructive) {
                            viewModel.history.clearAll()
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
            .padding(8)

            // Refresh
            Button {
                Task { await viewModel.loadPR() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading || viewModel.prMetadata == nil)
            .keyboardShortcut("r", modifiers: .command)

            Spacer()

            // Draft count badge
            if !viewModel.draftComments.isEmpty {
                Text("\(viewModel.draftComments.count) draft\(viewModel.draftComments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.2))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }

            // Inspector toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showInspector.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            // Submit review
            Menu {
                Button("Comment") {
                    Task { await viewModel.submitReview(event: .comment) }
                }
                Button("Approve") {
                    Task { await viewModel.submitReview(event: .approve) }
                }
                Button("Request Changes") {
                    Task { await viewModel.submitReview(event: .requestChanges) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                    Text("Submit Review")
                }
            }
            .disabled(viewModel.draftComments.isEmpty && viewModel.reviewBody.isEmpty)
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(viewModel.draftComments.isEmpty ? Color.secondary.opacity(0.2) : Color.green)
            .foregroundStyle(viewModel.draftComments.isEmpty ? Color.secondary : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
