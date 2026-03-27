import Testing
import Foundation
@testable import Parley

@Suite("GitHubClient")
struct GitHubClientTests {
    @Test("builds correct API URL for PR endpoint")
    func apiURL() {
        let url = GitHubClient.apiURL(owner: "jelmersnoeck", repo: "keps", path: "pulls/6")
        #expect(url.absoluteString == "https://api.github.com/repos/jelmersnoeck/keps/pulls/6")
    }

    @Test("builds correct API URL for contents endpoint")
    func contentsURL() {
        let url = GitHubClient.apiURL(
            owner: "foo",
            repo: "bar",
            path: "contents/docs/readme.md",
            queryItems: [URLQueryItem(name: "ref", value: "abc123")]
        )
        #expect(url.absoluteString == "https://api.github.com/repos/foo/bar/contents/docs/readme.md?ref=abc123")
    }

    @Test("parses PR metadata from JSON")
    func parsePRMetadata() throws {
        let json: [String: Any] = [
            "title": "Test PR",
            "body": "Description",
            "state": "closed",
            "merged": true,
            "user": ["login": "testuser", "avatar_url": "https://example.com/avatar"],
            "head": ["sha": "abc123", "ref": "feature-branch"],
            "base": ["ref": "main"]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let pr = try GitHubClient.parsePRResponse(
            data: data,
            owner: "foo",
            repo: "bar",
            number: 1,
            markdownFilePath: "docs/readme.md"
        )
        #expect(pr.title == "Test PR")
        #expect(pr.state == .merged)
        #expect(pr.author == "testuser")
        #expect(pr.headSHA == "abc123")
    }

    @Test("parses review comments from JSON")
    func parseReviewComments() throws {
        let json: [[String: Any]] = [
            [
                "id": 123,
                "user": ["login": "reviewer", "avatar_url": "https://example.com/avatar"],
                "body": "Looks good",
                "line": 42,
                "original_line": 42,
                "path": "docs/readme.md",
                "in_reply_to_id": NSNull(),
                "created_at": "2026-03-25T18:27:54Z",
                "side": "RIGHT"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let comments = try GitHubClient.parseReviewComments(data: data)
        #expect(comments.count == 1)
        #expect(comments[0].author == "reviewer")
        #expect(comments[0].line == 42)
        #expect(comments[0].inReplyToId == nil)
    }

    @Test("groups comments into threads")
    func groupThreads() {
        let comments = [
            ReviewComment(id: 1, author: "a", authorAvatarURL: "", body: "q", line: 23, originalLine: 23, path: "f.md", inReplyToId: nil, createdAt: Date(), side: "RIGHT"),
            ReviewComment(id: 2, author: "b", authorAvatarURL: "", body: "a", line: 23, originalLine: 23, path: "f.md", inReplyToId: 1, createdAt: Date(), side: "RIGHT"),
            ReviewComment(id: 3, author: "c", authorAvatarURL: "", body: "q2", line: 50, originalLine: 50, path: "f.md", inReplyToId: nil, createdAt: Date(), side: "RIGHT"),
        ]
        let threads = GitHubClient.groupIntoThreads(comments)
        #expect(threads.count == 2)
        #expect(threads[0].comments.count == 2)
        #expect(threads[1].comments.count == 1)
    }
}
