@testable import Convos
import ConvosCore
import Foundation
import Testing

struct DocGroupRelationshipTests {
    @Test("control loading never flashes standalone")
    func loadingDoesNotFlashStandalone() {
        let relationship = DocGroupRelationship.project(
            doc: makeDoc(editorialState: .none),
            controlBinding: nil,
            isControlLoaded: false,
            content: nil
        )

        #expect(relationship == .loading)
    }

    @Test("control relationship outranks editorial compatibility state")
    func controlOutranksEditorialState() {
        let doc = makeDoc(editorialState: .live, editorialGroup: "Old name")
        let relationship = DocGroupRelationship.project(
            doc: doc,
            controlBinding: makeBinding(status: .released, groupName: "Tahoe Weekend"),
            isControlLoaded: true,
            content: nil
        )

        #expect(relationship == .ended(identity: DocGroupIdentity(
            groupName: "Tahoe Weekend",
            observedMembers: ["Sara"]
        )))
    }

    @Test("direct-message control facts do not become group relationships")
    func directMessageIsExcluded() {
        let relationship = DocGroupRelationship.project(
            doc: makeDoc(),
            controlBinding: makeBinding(status: .live, conversationType: .dm),
            isControlLoaded: true,
            content: nil
        )

        #expect(relationship == .standalone)
    }

    @Test("unnamed groups use observed names and numbers as identity")
    func unnamedGroupUsesObservedSenders() throws {
        let content = DocContent(
            docId: "tahoe-trip",
            markdown: "# Tahoe",
            changes: [
                DocLastChange(who: "+16283095734", what: "added the cabin", at: .now),
                DocLastChange(who: "Noah", what: "added flights", at: .now),
                DocLastChange(who: "Someone", what: "added dinner", at: .now),
            ],
            updatedAt: .now
        )
        let relationship = DocGroupRelationship.project(
            doc: makeDoc(),
            controlBinding: makeBinding(status: .live, groupName: nil),
            isControlLoaded: true,
            content: content
        )
        guard case .connected(let identity, _) = relationship else {
            Issue.record("Expected a connected relationship")
            return
        }

        #expect(identity.homeHeadline == "Connected to your group with +1 (628) 309-5734, Noah, Sara")
        #expect(identity.hasUnidentifiedUpdates)
        #expect(identity.namedGroupMemberContext == nil)
    }

    @Test("named groups keep observed members as secondary context")
    func namedGroupUsesSecondaryMemberContext() throws {
        let relationship = DocGroupRelationship.project(
            doc: makeDoc(),
            controlBinding: makeBinding(status: .live, groupName: "Tahoe Weekend"),
            isControlLoaded: true,
            content: nil
        )
        guard case .connected(let identity, _) = relationship else {
            Issue.record("Expected a connected relationship")
            return
        }

        #expect(identity.homeHeadline == "Connected to Tahoe Weekend")
        #expect(identity.namedGroupMemberContext == "With Sara")
    }

    @Test("renamed groups update the same relationship copy")
    func renamedGroupUpdatesCopy() throws {
        let doc = makeDoc()
        let original = DocGroupRelationship.project(
            doc: doc,
            controlBinding: makeBinding(status: .live, groupName: "Tahoe"),
            isControlLoaded: true,
            content: nil
        )
        let renamed = DocGroupRelationship.project(
            doc: doc,
            controlBinding: makeBinding(status: .live, groupName: "Tahoe Weekend"),
            isControlLoaded: true,
            content: nil
        )
        guard case .connected(let originalIdentity, _) = original,
              case .connected(let renamedIdentity, _) = renamed else {
            Issue.record("Expected connected relationships")
            return
        }

        #expect(originalIdentity.homeHeadline == "Connected to Tahoe")
        #expect(renamedIdentity.homeHeadline == "Connected to Tahoe Weekend")
    }

    @Test("connection share text is exact and document scoped")
    func connectionShareTextIsExact() {
        #expect(DocGroupShareCopy.text(
            docName: "Tahoe Trip",
            lineNumber: "+16283095734"
        ) == "Add @doc to this iMessage group, then send any message there so I can connect it to “Tahoe Trip”: +1 (628) 309-5734")
    }

    @Test("one-group conflict copy names both sides and safe actions")
    func conflictCopyIsExact() {
        let copy = DocGroupConflictCopy(
            groupName: "Tahoe Weekend",
            connectedDocName: "Tahoe Trip"
        )

        #expect(copy.headline == "Tahoe Weekend is already connected to Tahoe Trip.")
        #expect(copy.context == "A group can update one doc.")
        #expect(copy.openAction == "Open Tahoe Trip")
        #expect(copy.keepAction == "Keep this standalone")
    }

    @Test("only the exact legacy relationship question gets dedicated treatment")
    func confirmationShapeIsNarrow() {
        let confirmation = DocWaitingItem(
            id: "connect",
            kind: .question,
            headline: "Is Tahoe Weekend your Tahoe Trip group?",
            context: "Choose a group.",
            chips: ["Yes, bind it", "No"],
            docId: "tahoe-trip",
            createdAt: .now
        )
        let ordinaryQuestion = DocWaitingItem(
            id: "date",
            kind: .question,
            headline: "Which weekend works?",
            context: "Choose a date.",
            chips: ["Dec 14", "Dec 21"],
            docId: "tahoe-trip",
            createdAt: .now
        )

        #expect(DocGroupConfirmationPresentation.matches(confirmation))
        #expect(!DocGroupConfirmationPresentation.matches(ordinaryQuestion))
        #expect(DocGroupConfirmationPresentation.confirmLabel == "Yes, connect")
        #expect(DocGroupConfirmationPresentation.legacyConfirmValue == "Yes, bind it")
        #expect(DocGroupConfirmationPresentation.rejectLabel == "Not this group")
        #expect(DocGroupConfirmationPresentation.legacyRejectValue == "No")
    }

    @Test("unmatched auto groups render control-backed progress copy")
    func unmatchedGroupProgressCopy() {
        #expect(DocUnmatchedGroupProgress(id: "named", groupName: "Tahoe Weekend").body ==
            "Making a doc for Tahoe Weekend…")
        #expect(DocUnmatchedGroupProgress(id: "unnamed", groupName: nil).body ==
            "Making a doc for a new iMessage group…")
    }

    private func makeDoc(
        editorialState: DocBinding.State = .none,
        editorialGroup: String? = nil
    ) -> DocStatus {
        DocStatus(
            id: "tahoe-trip",
            name: "Tahoe Trip",
            url: "https://docs.google.com/document/d/tahoe",
            updatedAt: .now,
            lastChange: DocLastChange(who: "Sara", what: "added flights", at: .now),
            binding: DocBinding(
                state: editorialState,
                number: editorialState == .none ? "" : "+16283095734",
                group: editorialGroup
            ),
            people: 3
        )
    }

    private func makeBinding(
        status: DocControlBinding.Status,
        conversationType: DocControlBinding.ConversationType = .group,
        groupName: String? = "Tahoe Weekend"
    ) -> DocControlBinding {
        DocControlBinding(
            status: status,
            lineNumber: "+16283095734",
            threadId: "thread-1",
            conversationType: conversationType,
            groupName: groupName,
            docId: "tahoe-trip",
            intentAt: 1_787_720_300,
            boundAt: 1_787_720_400,
            releasedAt: status == .released ? 1_787_720_600 : nil,
            supersedesKey: nil
        )
    }
}
