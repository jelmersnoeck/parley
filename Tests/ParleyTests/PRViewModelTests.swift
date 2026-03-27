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
}
