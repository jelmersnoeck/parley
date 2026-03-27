import Testing
@testable import Parley

@Suite("PRURLParser")
struct PRURLParserTests {
    @Test("parses standard GitHub PR URL")
    func standardURL() throws {
        let result = try PRURLParser.parse("https://github.com/jelmersnoeck/keps/pull/6")
        #expect(result.owner == "jelmersnoeck")
        #expect(result.repo == "keps")
        #expect(result.number == 6)
    }

    @Test("parses URL with trailing slash")
    func trailingSlash() throws {
        let result = try PRURLParser.parse("https://github.com/foo/bar/pull/42/")
        #expect(result.owner == "foo")
        #expect(result.repo == "bar")
        #expect(result.number == 42)
    }

    @Test("parses URL with files tab")
    func filesTab() throws {
        let result = try PRURLParser.parse("https://github.com/foo/bar/pull/42/files")
        #expect(result.owner == "foo")
        #expect(result.repo == "bar")
        #expect(result.number == 42)
    }

    @Test("rejects non-GitHub URL")
    func nonGitHub() {
        #expect(throws: PRURLParser.ParseError.self) {
            try PRURLParser.parse("https://gitlab.com/foo/bar/merge_requests/1")
        }
    }

    @Test("rejects malformed PR URL")
    func malformed() {
        #expect(throws: PRURLParser.ParseError.self) {
            try PRURLParser.parse("https://github.com/foo/bar")
        }
    }

    @Test("rejects non-numeric PR number")
    func nonNumeric() {
        #expect(throws: PRURLParser.ParseError.self) {
            try PRURLParser.parse("https://github.com/foo/bar/pull/abc")
        }
    }
}
