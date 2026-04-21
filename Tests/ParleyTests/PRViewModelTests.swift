import Testing
import Foundation
@testable import Parley

@Suite("PRViewModel")
struct PRViewModelTests {
    @Test("adds draft comment")
    @MainActor
    func addDraft() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 42, body: "needs work", path: "doc.md")
        #expect(vm.draftComments.count == 1)
        #expect(vm.draftComments[0].line == 42)
        #expect(vm.draftComments[0].body == "needs work")
    }

    @Test("removes draft comment by ID")
    @MainActor
    func removeDraft() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "a", path: "doc.md")
        vm.addDraftComment(line: 20, body: "b", path: "doc.md")
        let idToRemove = vm.draftComments[0].id
        vm.removeDraftComment(id: idToRemove)
        #expect(vm.draftComments.count == 1)
        #expect(vm.draftComments[0].body == "b")
    }

    @Test("updates draft comment body")
    @MainActor
    func updateDraft() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "old", path: "doc.md")
        let id = vm.draftComments[0].id
        vm.updateDraftComment(id: id, body: "new")
        #expect(vm.draftComments[0].body == "new")
    }

    @Test("builds submit review request from drafts")
    @MainActor
    func buildReviewRequest() {
        let vm = PRViewModel()
        vm.headSHA = "abc123"
        vm.reviewBody = "Overall looks good"
        vm.addDraftComment(line: 10, body: "fix this", path: "doc.md")
        vm.addDraftComment(line: 20, body: "and this", path: "doc.md")

        let request = vm.buildReviewRequest(event: .comment)
        #expect(request.commitId == "abc123")
        #expect(request.body == "Overall looks good")
        #expect(request.event == .comment)
        #expect(request.comments.count == 2)
        #expect(request.comments[0].line == 10)
        #expect(request.comments[1].line == 20)
    }

    @Test("clears drafts after submission")
    @MainActor
    func clearDrafts() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "fix", path: "doc.md")
        vm.clearDrafts()
        #expect(vm.draftComments.isEmpty)
        #expect(vm.reviewBody.isEmpty)
    }

    @Test("update with empty body removes draft")
    @MainActor
    func updateDraftEmptyBodyRemoves() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "Troy Barnes was here", path: "doc.md")
        let id = vm.draftComments[0].id
        vm.updateDraftComment(id: id, body: "   \n  ")
        // Empty/whitespace body triggers deletion — single source of truth in the model
        #expect(vm.draftComments.isEmpty)
    }

    @Test("update non-existent UUID is a no-op")
    @MainActor
    func updateDraftNonExistentId() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "Señor Chang", path: "doc.md")
        let bogusId = UUID()
        vm.updateDraftComment(id: bogusId, body: "this should do nothing")
        #expect(vm.draftComments.count == 1)
        #expect(vm.draftComments[0].body == "Señor Chang")
    }

    @Test("update preserves other drafts on same line")
    @MainActor
    func updateDraftPreservesOthers() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 42, body: "Human Being mascot", path: "doc.md")
        vm.addDraftComment(line: 42, body: "Greendale Community College", path: "doc.md")
        let firstId = vm.draftComments[0].id
        vm.updateDraftComment(id: firstId, body: "Pop pop!")
        #expect(vm.draftComments.count == 2)
        #expect(vm.draftComments[0].body == "Pop pop!")
        #expect(vm.draftComments[1].body == "Greendale Community College")
    }

    @Test("remove non-existent UUID is a no-op")
    @MainActor
    func removeDraftNonExistentId() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "cool cool cool", path: "doc.md")
        vm.removeDraftComment(id: UUID())
        #expect(vm.draftComments.count == 1)
    }

    @Test("update with identical body is a no-op")
    @MainActor
    func updateDraftSameBody() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "Streets ahead", path: "doc.md")
        let id = vm.draftComments[0].id
        vm.updateDraftComment(id: id, body: "Streets ahead")
        #expect(vm.draftComments.count == 1)
        #expect(vm.draftComments[0].body == "Streets ahead")
    }

    @Test("update with very long body truncates to maxBodyLength")
    @MainActor
    func updateDraftLongBodyTruncates() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, body: "short", path: "doc.md")
        let id = vm.draftComments[0].id
        // Boundary: exactly maxBodyLength + 1 to test truncation edge
        let longBody = String(repeating: "A", count: PRViewModel.maxBodyLength + 1)
        vm.updateDraftComment(id: id, body: longBody)
        #expect(vm.draftComments[0].body.count == PRViewModel.maxBodyLength)
    }

    // MARK: - Line number validation

    @Test("addDraftComment rejects zero line")
    @MainActor
    func addDraftRejectsZeroLine() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 0, body: "Abed Nadir", path: "doc.md")
        #expect(vm.draftComments.isEmpty)
    }

    @Test("addDraftComment rejects negative line")
    @MainActor
    func addDraftRejectsNegativeLine() {
        let vm = PRViewModel()
        vm.addDraftComment(line: -1, body: "Dean Pelton", path: "doc.md")
        #expect(vm.draftComments.isEmpty)
    }

    @Test("addDraftComment rejects line beyond max")
    @MainActor
    func addDraftRejectsOverflowLine() {
        let vm = PRViewModel()
        vm.addDraftComment(line: WebViewCoordinator.maxLineNumber + 1, body: "Magnitude", path: "doc.md")
        #expect(vm.draftComments.isEmpty)
    }

    @Test("addDraftComment accepts line at max boundary")
    @MainActor
    func addDraftAcceptsMaxLine() {
        let vm = PRViewModel()
        vm.addDraftComment(line: WebViewCoordinator.maxLineNumber, body: "Pop pop!", path: "doc.md")
        #expect(vm.draftComments.count == 1)
    }

    @Test("addDraftComment rejects startLine greater than line")
    @MainActor
    func addDraftRejectsStartLineAfterLine() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, startLine: 20, body: "Britta Perry", path: "doc.md")
        #expect(vm.draftComments.isEmpty)
    }

    @Test("addDraftComment rejects zero startLine")
    @MainActor
    func addDraftRejectsZeroStartLine() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, startLine: 0, body: "Jeff Winger", path: "doc.md")
        #expect(vm.draftComments.isEmpty)
    }

    @Test("addDraftComment accepts valid startLine")
    @MainActor
    func addDraftAcceptsValidStartLine() {
        let vm = PRViewModel()
        vm.addDraftComment(line: 10, startLine: 5, body: "Annie Edison", path: "doc.md")
        #expect(vm.draftComments.count == 1)
        #expect(vm.draftComments[0].startLine == 5)
    }
}
