@testable import Convos
import ConvosCore
import Foundation
import Testing

struct DocDraftSubmissionTests {
    @Test("edited draft preserves markdown source in the outgoing payload")
    func editedDraftPreservesMarkdownSourceInOutgoingPayload() throws {
        let fixture = "## Decisions\n\n- **Date:** Dec 14\n- Owner: Sara"
        let editorBackingSource = DocDraftMarkdown.attributedString(from: fixture).string
        let editedSource = editorBackingSource.replacingOccurrences(of: "Sara", with: "Jordan")
        let answer = DocDraftSubmission.approvalAnswer(
            originalSource: fixture,
            editedSource: editedSource
        )
        let payload = try #require(DocAnswerMessage.encode(itemId: "draft-1", answer: answer))
        let json = try decodedPayload(payload)

        #expect(editorBackingSource == fixture)
        #expect(json["edited"] as? String == "## Decisions\n\n- **Date:** Dec 14\n- Owner: Jordan")
    }

    @Test("untouched draft omits the edited field")
    func untouchedDraftOmitsEditedField() throws {
        let fixture = "## Decisions\n\n- Tahoe weekend: December 14"
        let editorBackingSource = DocDraftMarkdown.attributedString(from: fixture).string
        let answer = DocDraftSubmission.approvalAnswer(
            originalSource: fixture,
            editedSource: editorBackingSource
        )
        let payload = try #require(DocAnswerMessage.encode(itemId: "draft-2", answer: answer))
        let json = try decodedPayload(payload)

        #expect(editorBackingSource == fixture)
        #expect(json["action"] as? String == "approve")
        #expect(json["edited"] == nil)
    }

    @Test("draft feedback uses a short selection-scoped composer prompt")
    func draftFeedbackUsesSelectionScopedPrompt() {
        let source = """
        ## Decisions

        - Cabin checkout is Thursday morning after breakfast.
        - Jordan will bring tire chains and groceries for the group.
        """

        let message = DocDraftFeedbackPrompt.message(
            draftSource: source,
            docName: "Tahoe Trip"
        )

        #expect(message.hasPrefix("Re \"## Decisions - Cabin checkout is Thursday"))
        #expect(message.hasSuffix("\" in Tahoe Trip: "))
        #expect(message.count < 120)
    }

    private func decodedPayload(_ message: String) throws -> [String: Any] {
        let payload = String(message.dropFirst(DocAnswerMessage.prefix.count))
        let data = try #require(payload.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
