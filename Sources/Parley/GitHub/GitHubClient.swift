import Foundation

actor GitHubClient {
    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    // MARK: - Token retrieval

    /// Locate the `gh` binary. GUI apps launched from Finder/Dock don't inherit
    /// the shell PATH, so /usr/bin/env can't find Homebrew binaries. We check
    /// common install locations explicitly.
    private static func findGH() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/gh",   // Homebrew (Apple Silicon)
            "/usr/local/bin/gh",      // Homebrew (Intel) / manual install
            "/usr/bin/gh",            // unlikely but possible
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: path) {
                return url
            }
        }
        return nil
    }

    static func tokenFromGH() async throws -> String {
        guard let ghURL = findGH() else {
            throw ClientError.ghCLINotAuthenticated
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = ghURL
        process.arguments = ["auth", "token"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ClientError.ghCLINotAuthenticated
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw ClientError.ghCLINotAuthenticated
        }
        return token
    }

    // MARK: - URL building

    static func apiURL(owner: String, repo: String, path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url!
    }

    // MARK: - API requests

    private func request(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw ClientError.unauthorized
        case 403:
            throw ClientError.forbidden
        case 404:
            throw ClientError.notFound
        case 429:
            let resetTime = http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "unknown"
            throw ClientError.rateLimited(resetAt: resetTime)
        default:
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw ClientError.apiError(statusCode: http.statusCode, body: body)
        }
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 429:
            let resetTime = http.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "unknown"
            throw ClientError.rateLimited(resetAt: resetTime)
        default:
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            throw ClientError.apiError(statusCode: http.statusCode, body: responseBody)
        }
    }

    // MARK: - Fetch PR

    func fetchPR(owner: String, repo: String, number: Int) async throws -> (PRMetadata, [CommentThread]) {
        let prURL = Self.apiURL(owner: owner, repo: repo, path: "pulls/\(number)")
        let prData = try await request(prURL)

        let filesURL = Self.apiURL(owner: owner, repo: repo, path: "pulls/\(number)/files")
        let filesData = try await request(filesURL)
        let filesJSON = try JSONSerialization.jsonObject(with: filesData) as! [[String: Any]]
        let mdFile = filesJSON.first { ($0["filename"] as? String)?.hasSuffix(".md") == true }

        guard let markdownPath = mdFile?["filename"] as? String else {
            throw ClientError.noMarkdownFile
        }

        let metadata = try Self.parsePRResponse(
            data: prData,
            owner: owner,
            repo: repo,
            number: number,
            markdownFilePath: markdownPath
        )

        let commentsURL = Self.apiURL(owner: owner, repo: repo, path: "pulls/\(number)/comments",
                                       queryItems: [URLQueryItem(name: "per_page", value: "100")])
        let commentsData = try await request(commentsURL)
        let comments = try Self.parseReviewComments(data: commentsData)
        let threads = Self.groupIntoThreads(comments)

        return (metadata, threads)
    }

    // MARK: - Fetch raw file content

    func fetchFileContent(owner: String, repo: String, path: String, ref: String) async throws -> String {
        let url = Self.apiURL(
            owner: owner, repo: repo,
            path: "contents/\(path)",
            queryItems: [URLQueryItem(name: "ref", value: ref)]
        )

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ClientError.notFound
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw ClientError.invalidResponse
        }
        return content
    }

    // MARK: - Submit review

    func submitReview(owner: String, repo: String, number: Int, review: SubmitReviewRequest) async throws {
        let url = Self.apiURL(owner: owner, repo: repo, path: "pulls/\(number)/reviews")
        var body: [String: Any] = [
            "commit_id": review.commitId,
            "event": review.event.rawValue,
        ]
        if !review.body.isEmpty {
            body["body"] = review.body
        }
        if !review.comments.isEmpty {
            body["comments"] = review.comments.map { comment in
                var c: [String: Any] = [
                    "path": comment.path,
                    "line": comment.line,
                    "side": comment.side,
                    "body": comment.body,
                ]
                if let startLine = comment.startLine, startLine != comment.line {
                    c["start_line"] = startLine
                    c["start_side"] = comment.side
                }
                return c
            }
        }
        _ = try await post(url, body: body)
    }

    // MARK: - Reply to existing thread

    func replyToComment(owner: String, repo: String, number: Int, inReplyTo: Int, body: String) async throws {
        let url = Self.apiURL(owner: owner, repo: repo, path: "pulls/\(number)/comments")
        let requestBody: [String: Any] = [
            "body": body,
            "in_reply_to": inReplyTo,
        ]
        _ = try await post(url, body: requestBody)
    }

    // MARK: - Parsing

    static func parsePRResponse(data: Data, owner: String, repo: String, number: Int, markdownFilePath: String) throws -> PRMetadata {
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let user = json["user"] as! [String: Any]
        let head = json["head"] as! [String: Any]
        let base = json["base"] as! [String: Any]
        let merged = json["merged"] as? Bool ?? false

        return PRMetadata(
            owner: owner,
            repo: repo,
            number: number,
            title: json["title"] as? String ?? "",
            body: json["body"] as? String ?? "",
            state: PRState(from: json["state"] as? String ?? "open", merged: merged),
            author: user["login"] as? String ?? "",
            headSHA: head["sha"] as? String ?? "",
            baseRef: base["ref"] as? String ?? "",
            headRef: head["ref"] as? String ?? "",
            markdownFilePath: markdownFilePath
        )
    }

    static func parseReviewComments(data: Data) throws -> [ReviewComment] {
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let formatter = ISO8601DateFormatter()

        return json.map { item in
            let user = item["user"] as? [String: Any] ?? [:]
            let replyId = item["in_reply_to_id"] as? Int

            return ReviewComment(
                id: item["id"] as? Int ?? 0,
                author: user["login"] as? String ?? "",
                authorAvatarURL: user["avatar_url"] as? String ?? "",
                body: item["body"] as? String ?? "",
                line: item["line"] as? Int,
                originalLine: item["original_line"] as? Int ?? 0,
                path: item["path"] as? String ?? "",
                inReplyToId: replyId,
                createdAt: formatter.date(from: item["created_at"] as? String ?? "") ?? Date(),
                side: item["side"] as? String ?? "RIGHT"
            )
        }
    }

    static func groupIntoThreads(_ comments: [ReviewComment]) -> [CommentThread] {
        var rootMap: [Int: [ReviewComment]] = [:]
        var rootOrder: [Int] = []

        for comment in comments {
            switch comment.inReplyToId {
            case nil:
                rootMap[comment.id] = [comment]
                rootOrder.append(comment.id)
            case let parentId?:
                rootMap[parentId, default: []].append(comment)
            }
        }

        return rootOrder.compactMap { rootId in
            guard let threadComments = rootMap[rootId],
                  let root = threadComments.first else { return nil }
            let line = root.line ?? root.originalLine
            return CommentThread(id: rootId, line: line, comments: threadComments)
        }
    }

    // MARK: - Errors

    enum ClientError: Error, CustomStringConvertible {
        case ghCLINotAuthenticated
        case unauthorized
        case forbidden
        case notFound
        case noMarkdownFile
        case invalidResponse
        case rateLimited(resetAt: String)
        case apiError(statusCode: Int, body: String)

        var description: String {
            switch self {
            case .ghCLINotAuthenticated: "GitHub CLI not authenticated. Run `gh auth login` first."
            case .unauthorized: "Unauthorized — check your GitHub token."
            case .forbidden: "Forbidden — insufficient permissions."
            case .notFound: "Not found — check the PR URL."
            case .noMarkdownFile: "No markdown file found in this PR."
            case .invalidResponse: "Invalid response from GitHub API."
            case .rateLimited(let resetAt): "Rate limited. Resets at: \(resetAt)"
            case .apiError(let code, let body): "GitHub API error (\(code)): \(body)"
            }
        }
    }
}
