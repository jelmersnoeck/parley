import Foundation
import SwiftUI

@Observable
@MainActor
final class PRViewModel {
    /// Maximum allowed length for a draft comment body. Shared with JS via coordinator injection.
    static let maxBodyLength = 100_000

    // MARK: - State

    var urlInput: String = ""
    var isLoading: Bool = false
    var errorMessage: String?
    var showInspector: Bool = false
    let history = HistoryManager()

    // PR data
    var prMetadata: PRMetadata?
    var markdownContent: String = ""
    var commentThreads: [CommentThread] = []

    // Review drafting
    var draftComments: [DraftComment] = []
    var reviewBody: String = ""
    var headSHA: String = ""

    // Set to scroll the webview to a specific line, cleared after use
    var scrollTarget: Int?

    // MARK: - Draft management

    func addDraftComment(line: Int, startLine: Int? = nil, body: String, path: String) {
        let draft = DraftComment(line: line, startLine: startLine, body: body, path: path)
        draftComments.append(draft)
    }

    func removeDraftComment(id: UUID) {
        draftComments.removeAll { $0.id == id }
    }

    /// Updates a draft comment's body. Empty/whitespace-only body removes the draft.
    ///
    /// This is the single source of truth for "empty means delete" logic — callers
    /// (coordinator, inspector panel, JS) should NOT duplicate this check.
    func updateDraftComment(id: UUID, body: String) {
        guard let index = draftComments.firstIndex(where: { $0.id == id }) else { return }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftComments.remove(at: index)
        } else {
            draftComments[index].body = body
        }
    }

    func clearDrafts() {
        draftComments.removeAll()
        reviewBody = ""
    }

    func buildReviewRequest(event: ReviewEvent) -> SubmitReviewRequest {
        SubmitReviewRequest(
            commitId: headSHA,
            body: reviewBody,
            event: event,
            comments: draftComments.map { draft in
                SubmitReviewRequest.InlineComment(
                    path: draft.path,
                    line: draft.line,
                    startLine: draft.startLine,
                    side: "RIGHT",
                    body: draft.body
                )
            }
        )
    }

    // MARK: - Load PR

    func loadPR() async {
        let urlString = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }

        do {
            let ref = try PRURLParser.parse(urlString)
            isLoading = true
            errorMessage = nil

            let token = try await GitHubClient.tokenFromGH()
            let client = GitHubClient(token: token)

            let (metadata, threads) = try await client.fetchPR(
                owner: ref.owner,
                repo: ref.repo,
                number: ref.number
            )

            let content = try await client.fetchFileContent(
                owner: ref.owner,
                repo: ref.repo,
                path: metadata.markdownFilePath,
                ref: metadata.headSHA
            )

            prMetadata = metadata
            markdownContent = resolveImageURLs(
                in: content,
                owner: ref.owner,
                repo: ref.repo,
                ref: metadata.headSHA
            )
            commentThreads = threads
            headSHA = metadata.headSHA
            isLoading = false

            history.recordVisit(
                url: urlString,
                title: metadata.title,
                owner: ref.owner,
                repo: ref.repo,
                number: ref.number
            )
        } catch {
            errorMessage = String(describing: error)
            isLoading = false
        }
    }

    // MARK: - Submit review

    func submitReview(event: ReviewEvent) async {
        guard let metadata = prMetadata else { return }

        do {
            isLoading = true
            let token = try await GitHubClient.tokenFromGH()
            let client = GitHubClient(token: token)
            let request = buildReviewRequest(event: event)

            try await client.submitReview(
                owner: metadata.owner,
                repo: metadata.repo,
                number: metadata.number,
                review: request
            )

            clearDrafts()
            await loadPR()
        } catch {
            errorMessage = String(describing: error)
            isLoading = false
        }
    }

    // MARK: - Reply to existing thread

    func replyToThread(commentId: Int, body: String) async {
        guard let metadata = prMetadata else { return }

        do {
            let token = try await GitHubClient.tokenFromGH()
            let client = GitHubClient(token: token)
            try await client.replyToComment(
                owner: metadata.owner,
                repo: metadata.repo,
                number: metadata.number,
                inReplyTo: commentId,
                body: body
            )
            await loadPR()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Image URL resolution

    private func resolveImageURLs(in markdown: String, owner: String, repo: String, ref: String) -> String {
        let pattern = #"!\[([^\]]*)\]\((?!https?://)([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }

        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.stringByReplacingMatches(
            in: markdown,
            range: range,
            withTemplate: "![$1](https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/$2)"
        )
    }
}
