import SwiftUI

struct StatusBarView: View {
    let viewModel: PRViewModel

    var body: some View {
        HStack(spacing: 16) {
            if let pr = viewModel.prMetadata {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                    Text("\(viewModel.commentThreads.flatMap(\.comments).count) comments")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !viewModel.draftComments.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("\(viewModel.draftComments.count) drafts")
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                }

                Spacer()

                Text(pr.markdownFilePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PRStateBadge(state: pr.state)
            } else if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Paste a GitHub PR URL above to get started")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
