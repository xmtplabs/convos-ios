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

    private func decodedPayload(_ message: String) throws -> [String: Any] {
        let payload = String(message.dropFirst(DocAnswerMessage.prefix.count))
        let data = try #require(payload.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
