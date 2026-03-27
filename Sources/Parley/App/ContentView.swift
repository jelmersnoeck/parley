import SwiftUI

struct ContentView: View {
    @State private var viewModel = PRViewModel()

    var body: some View {
        VStack(spacing: 0) {
            PRToolbar(viewModel: viewModel)
            Divider()

            ZStack {
                Color(nsColor: .windowBackgroundColor)

                if viewModel.isLoading && viewModel.markdownContent.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading PR...")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Retry") {
                            Task { await viewModel.loadPR() }
                        }
                    }
                } else if viewModel.markdownContent.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Paste a GitHub PR URL to start reviewing")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                } else {
                    HStack(spacing: 0) {
                        MarkdownWebView(viewModel: viewModel)

                        if viewModel.showInspector {
                            Divider()
                            InspectorPanel(viewModel: viewModel)
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
            }

            Divider()
            StatusBarView(viewModel: viewModel)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
