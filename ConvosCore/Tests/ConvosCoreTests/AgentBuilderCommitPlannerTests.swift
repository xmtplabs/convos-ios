@testable import ConvosCore
import Foundation
import Testing

/// Coverage for `AgentBuilderCommitPlanner.makePlan` - the pure id-allocation
/// and summary-assembly step extracted out of `AgentBuilderViewModel.commit`.
/// The crash-safety contract is that `bundledMessageIds` exactly matches the
/// sends the builder issues (prompt text + media bundle), so the post-commit
/// list filters those bubbles by id rather than by a race-prone timestamp.
@Suite("AgentBuilderCommitPlanner Tests")
struct AgentBuilderCommitPlannerTests {
    /// Deterministic id source so message-id allocation can be asserted
    /// exactly. Records every id handed out so tests can also assert *how
    /// many* were allocated.
    private final class IdSequence {
        private(set) var issued: [String] = []
        func next() -> String {
            let id = "id-\(issued.count + 1)"
            issued.append(id)
            return id
        }
    }

    @Test("Text-only commit allocates a text id, no bundle id")
    func textOnlyAllocatesTextId() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "hello agent",
            attachments: [],
            cloudConnectionIds: [:],
            generateMessageId: ids.next
        )

        #expect(plan.textMessageId == "id-1")
        #expect(plan.bundleMessageId == nil)
        #expect(plan.summary.bundledMessageIds == ["id-1"])
        #expect(plan.summary.prompt == "hello agent")
        #expect(ids.issued == ["id-1"])
    }

    @Test("Voice-memo-only commit allocates a bundle id, no text id")
    func voiceMemoOnlyAllocatesBundleId() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "",
            attachments: [.voiceMemo(id: UUID(), duration: 3, levels: [0.1, 0.2])],
            cloudConnectionIds: [:],
            generateMessageId: ids.next
        )

        #expect(plan.textMessageId == nil)
        #expect(plan.bundleMessageId == "id-1")
        #expect(plan.summary.bundledMessageIds == ["id-1"])
        #expect(ids.issued == ["id-1"])
    }

    @Test("Text plus media bundles both ids, text allocated before bundle")
    func textPlusMediaAllocatesBothIds() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "make me a thing",
            attachments: [.photo(id: UUID(), thumbnailData: nil)],
            cloudConnectionIds: [:],
            generateMessageId: ids.next
        )

        #expect(plan.textMessageId == "id-1")
        #expect(plan.bundleMessageId == "id-2")
        #expect(plan.summary.bundledMessageIds == ["id-1", "id-2"])
        #expect(ids.issued == ["id-1", "id-2"])
    }

    @Test("Connections-only commit allocates no message ids and bundles nothing")
    func connectionsOnlyAllocatesNoIds() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "",
            attachments: [.connection(id: UUID(), identifier: "googleCalendar")],
            cloudConnectionIds: ["googleCalendar": "cloud-1"],
            generateMessageId: ids.next
        )

        #expect(plan.textMessageId == nil)
        #expect(plan.bundleMessageId == nil)
        #expect(plan.summary.bundledMessageIds.isEmpty)
        #expect(ids.issued.isEmpty)
        #expect(plan.summary.attachments.count == 1)
        #expect(plan.summary.cloudConnectionIds == ["googleCalendar": "cloud-1"])
    }

    @Test("A connection alongside media still allocates only the bundle id")
    func connectionDoesNotCountAsBundleable() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "",
            attachments: [
                .file(id: UUID(), filename: "a.pdf", mimeType: "application/pdf", fileSize: 10),
                .connection(id: UUID(), identifier: "appleHealth"),
            ],
            cloudConnectionIds: [:],
            generateMessageId: ids.next
        )

        // The file makes this bundleable; the connection alone never would.
        #expect(plan.bundleMessageId == "id-1")
        #expect(plan.summary.bundledMessageIds == ["id-1"])
    }

    @Test("Summary preserves attachment order, cutoffDate, and cloud ids")
    func summaryCarriesInputsThrough() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let voiceId = UUID()
        let photoId = UUID()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "hi",
            attachments: [
                .voiceMemo(id: voiceId, duration: 1, levels: []),
                .photo(id: photoId, thumbnailData: nil),
            ],
            cloudConnectionIds: ["googleCalendar": "cloud-9"],
            now: now,
            generateMessageId: { UUID().uuidString }
        )

        #expect(plan.summary.cutoffDate == now)
        #expect(plan.summary.attachments.map(\.id) == [voiceId, photoId])
        #expect(plan.summary.cloudConnectionIds == ["googleCalendar": "cloud-9"])
    }

    @Test("Empty prompt with no attachments allocates nothing")
    func emptyEverythingAllocatesNothing() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "",
            attachments: [],
            cloudConnectionIds: [:],
            generateMessageId: ids.next
        )

        #expect(plan.textMessageId == nil)
        #expect(plan.bundleMessageId == nil)
        #expect(plan.summary.bundledMessageIds.isEmpty)
        #expect(plan.summary.prompt.isEmpty)
        #expect(ids.issued.isEmpty)
    }

    @Test("Whitespace-only prompt is trimmed away: no text id, empty summary prompt")
    func whitespaceOnlyPromptAllocatesNoTextId() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "   \n\t  ",
            attachments: [],
            cloudConnectionIds: [:],
            generateMessageId: ids.next
        )

        #expect(plan.textMessageId == nil)
        #expect(plan.bundleMessageId == nil)
        #expect(plan.summary.bundledMessageIds.isEmpty)
        #expect(plan.summary.prompt.isEmpty)
        #expect(ids.issued.isEmpty)
    }

    @Test("Surrounding whitespace is trimmed from the canonical summary prompt")
    func promptIsTrimmedInSummary() {
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "  hello agent\n",
            attachments: [],
            cloudConnectionIds: [:],
            generateMessageId: { UUID().uuidString }
        )

        #expect(plan.summary.prompt == "hello agent")
        #expect(plan.textMessageId != nil)
    }

    @Test("Multiple media items still allocate exactly one bundle id")
    func multipleMediaAllocatesSingleBundleId() {
        let ids = IdSequence()
        let plan = AgentBuilderCommitPlanner.makePlan(
            prompt: "",
            attachments: [
                .photo(id: UUID(), thumbnailData: nil),
                .video(id: UUID(), thumbnailData: nil),
                .file(id: UUID(), filename: "a.pdf", mimeType: "application/pdf", fileSize: 10),
                .voiceMemo(id: UUID(), duration: 2, levels: []),
            ],
            cloudConnectionIds: [:],
            generateMessageId: ids.next
        )

        #expect(plan.textMessageId == nil)
        #expect(plan.bundleMessageId == "id-1")
        #expect(plan.summary.bundledMessageIds == ["id-1"])
        #expect(ids.issued == ["id-1"])
    }
}
