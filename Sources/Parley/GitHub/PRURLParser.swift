import Foundation

enum PRURLParser {
    struct PRReference: Equatable, Sendable {
        let owner: String
        let repo: String
        let number: Int
    }

    enum ParseError: Error, CustomStringConvertible {
        case invalidURL(String)
        case notGitHub(String)
        case notPullRequest(String)
        case invalidPRNumber(String)

        var description: String {
            switch self {
            case .invalidURL(let url): "Invalid URL: \(url)"
            case .notGitHub(let host): "Not a GitHub URL (host: \(host))"
            case .notPullRequest(let path): "Not a pull request URL: \(path)"
            case .invalidPRNumber(let segment): "Invalid PR number: \(segment)"
            }
        }
    }

    static func parse(_ urlString: String) throws -> PRReference {
        guard let url = URL(string: urlString) else {
            throw ParseError.invalidURL(urlString)
        }

        guard let host = url.host, host == "github.com" else {
            throw ParseError.notGitHub(url.host ?? "nil")
        }

        let segments = url.pathComponents.filter { $0 != "/" }

        guard segments.count >= 4,
              segments[2] == "pull" else {
            throw ParseError.notPullRequest(url.path)
        }

        guard let number = Int(segments[3]) else {
            throw ParseError.invalidPRNumber(segments[3])
        }

        return PRReference(owner: segments[0], repo: segments[1], number: number)
    }
}
