import Foundation

// MARK: - PR Metadata

struct PRMetadata: Sendable {
    let owner: String
    let repo: String
    let number: Int
    let title: String
    let body: String
    let state: PRState
    let author: String
    let headSHA: String
    let baseRef: String
    let headRef: String
    let markdownFilePath: String
}

enum PRState: String, Sendable {
    case open
    case closed
    case merged

    init(from apiState: String, merged: Bool) {
        switch (apiState.lowercased(), merged) {
        case (_, true): self = .merged
        case ("closed", _): self = .closed
        default: self = .open
        }
    }
}

// MARK: - Review Comments

struct ReviewComment: Identifiable, Sendable {
    let id: Int
    let author: String
    let authorAvatarURL: String
    let body: String
    let line: Int?
    let originalLine: Int
    let path: String
    let inReplyToId: Int?
    let createdAt: Date
    let side: String
}

// MARK: - Reviews

struct Review: Identifiable, Sendable {
    let id: Int
    let author: String
    let state: ReviewState
    let body: String
    let submittedAt: Date?
}

enum ReviewState: String, Sendable, Codable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case pending = "PENDING"
    case dismissed = "DISMISSED"
}

// MARK: - Draft Comments (local, not yet submitted)

struct DraftComment: Identifiable, Sendable {
    let id: UUID
    var line: Int          // end line (required by GH API)
    var startLine: Int?    // start line for multi-line selections
    var body: String
    let path: String
    let createdAt: Date

    init(line: Int, startLine: Int? = nil, body: String, path: String) {
        self.id = UUID()
        self.line = line
        self.startLine = startLine
        self.body = body
        self.path = path
        self.createdAt = Date()
    }

    var isMultiLine: Bool { startLine != nil && startLine != line }
    var displayLine: String {
        guard let start = startLine, start != line else { return "Line \(line)" }
        return "Lines \(start)-\(line)"
    }
}

// MARK: - Comment Threads (grouped for display)

struct CommentThread: Identifiable, Sendable {
    let id: Int // root comment ID
    let line: Int
    let comments: [ReviewComment]

    var rootComment: ReviewComment { comments[0] }
    var replies: [ReviewComment] { Array(comments.dropFirst()) }
}

// MARK: - Submit Review Request

struct SubmitReviewRequest: Sendable {
    let commitId: String
    let body: String
    let event: ReviewEvent
    let comments: [InlineComment]

    struct InlineComment: Sendable {
        let path: String
        let line: Int
        let startLine: Int?
        let side: String
        let body: String
    }
}

enum ReviewEvent: String, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
}
