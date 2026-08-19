import ConvosConnections
@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("Capability connect transcript")
struct CapabilityConnectTranscriptTests {
    private let asker: String = "agent-inbox"
    private let approver: String = "member-inbox"

    private func makeRequest(
        requestId: String = "req-1",
        preferredProviders: [ProviderID]? = [ProviderID(rawValue: "composio.googlecalendar")]
    ) -> CapabilityRequest {
        CapabilityRequest(
            requestId: requestId,
            askerInboxId: asker,
            subject: .calendar,
            capability: .read,
            rationale: "To book that meeting",
            preferredProviders: preferredProviders
        )
    }

    /// `sentAtNs`/`messageId` position the record in message time for the
    /// first-decision-wins ordering; the id defaults to one derived from the
    /// timestamp so single-record tests stay terse.
    private func record(
        from senderId: String,
        _ status: CapabilityRequestResult.Status,
        at sentAtNs: Int64 = 0,
        id messageId: String? = nil
    ) -> CapabilityConnectPrompt.ResultRecord {
        .init(
            senderId: senderId,
            status: status,
            sentAtNs: sentAtNs,
            messageId: messageId ?? "message-\(sentAtNs)"
        )
    }

    // MARK: - Status derivation (requestId join)

    @Test("no result rows leaves the prompt pending")
    func pendingWithoutResults() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .pending)
    }

    @Test("the viewer's own approval flips the prompt to connected")
    func connectedOnApproval() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [record(from: approver, .approved)],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .connected)
    }

    @Test("another member's approval leaves the prompt pending for the viewer")
    func otherMemberApprovalKeepsViewerPending() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [record(from: "another-member", .approved)],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .pending)
    }

    @Test("another member's denial leaves the prompt pending for the viewer")
    func otherMemberDenialKeepsViewerPending() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [record(from: "another-member", .denied)],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .pending)
    }

    @Test("the viewer's earlier denial dismisses even when their approval lands later")
    func earlierDenialWinsOverLaterApproval() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [
                record(from: approver, .denied, at: 1),
                record(from: approver, .approved, at: 2),
            ],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .dismissed)
    }

    @Test("the viewer's earlier approval connects even when their denial lands later")
    func earlierApprovalWinsOverLaterDenial() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [
                record(from: approver, .approved, at: 1),
                record(from: approver, .denied, at: 2),
            ],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .connected)
    }

    @Test("resolution orders by message time, not by array order")
    func resolutionIgnoresArrayOrder() {
        // The approval comes first in the array but was sent later — the
        // earlier denial must still win.
        let status = CapabilityConnectPrompt.displayStatus(
            results: [
                record(from: approver, .approved, at: 2),
                record(from: approver, .denied, at: 1),
            ],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .dismissed)
    }

    @Test("an asker denial earlier than the viewer's approval still connects")
    func askerDenialSkippedBeforeValidApproval() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [
                record(from: asker, .denied, at: 1),
                record(from: approver, .approved, at: 2),
            ],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .connected)
    }

    @Test("identical timestamps resolve deterministically via the message id tiebreaker")
    func identicalTimestampsUseMessageIdTiebreaker() {
        let results = [
            record(from: approver, .denied, at: 5, id: "message-b"),
            record(from: approver, .approved, at: 5, id: "message-a"),
        ]
        let status = CapabilityConnectPrompt.displayStatus(
            results: results,
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        let reversedStatus = CapabilityConnectPrompt.displayStatus(
            results: results.reversed(),
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        // "message-a" (the approval) sorts first regardless of array order.
        #expect(status == .connected)
        #expect(reversedStatus == .connected)
    }

    @Test("the viewer's denied and cancelled results dismiss the prompt")
    func dismissedOnDenyOrCancel() {
        let denied = CapabilityConnectPrompt.displayStatus(
            results: [record(from: approver, .denied)],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        let cancelled = CapabilityConnectPrompt.displayStatus(
            results: [record(from: approver, .cancelled)],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(denied == .dismissed)
        #expect(cancelled == .dismissed)
    }

    @Test("the asker cannot resolve its own request, even as the viewer")
    func askerResultsIgnored() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [record(from: asker, .approved)],
            askerInboxId: asker,
            viewerInboxId: asker,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .pending)
    }

    @Test("staleResource and unknown statuses are not user decisions")
    func nonDecisionStatusesStayPending() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [
                record(from: approver, .staleResource, at: 1),
                record(from: approver, .unknown, at: 2),
            ],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(status == .pending)
    }

    @Test("an unresolved request that is not the latest renders superseded")
    func supersededWhenNotLatestUnresolved() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: false
        )
        #expect(status == .superseded)
    }

    @Test("a request the viewer resolved stays resolved even when a newer request exists")
    func resolutionWinsOverSupersession() {
        let status = CapabilityConnectPrompt.displayStatus(
            results: [record(from: approver, .approved)],
            askerInboxId: asker,
            viewerInboxId: approver,
            isLatestUnresolvedRequest: false
        )
        #expect(status == .connected)
    }

    // MARK: - Prompt factory

    @Test("cloud preferred provider resolves brand name, slug, and icon")
    func cloudProviderBranding() {
        let prompt = CapabilityConnectPrompt.make(
            request: makeRequest(),
            results: [],
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(prompt.serviceName == "Google Calendar")
        #expect(prompt.serviceId == "googlecalendar")
        #expect(prompt.icon == .calendar)
        #expect(prompt.askerInboxId == asker)
        #expect(prompt.status == .pending)
    }

    @Test("missing preferred providers falls back to the subject name")
    func subjectFallback() {
        let prompt = CapabilityConnectPrompt.make(
            request: makeRequest(preferredProviders: nil),
            results: [],
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(prompt.serviceName == "Calendar")
        #expect(prompt.serviceId == nil)
        #expect(prompt.icon == .calendar)
    }

    @Test("device preferred provider uses the device spec display name")
    func deviceProviderName() {
        let prompt = CapabilityConnectPrompt.make(
            request: makeRequest(preferredProviders: [ProviderID(rawValue: "device.calendar")]),
            results: [],
            viewerInboxId: approver,
            isLatestUnresolvedRequest: true
        )
        #expect(prompt.serviceName == "Apple Calendar")
        #expect(prompt.serviceId == nil)
    }

    // MARK: - Hydration (compose-time join against GRDB rows)

    @Test("capability request row hydrates as a pending connect prompt")
    func hydratesPendingPrompt() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)

        let prompt = try #require(try harness.fetchPrompt())
        #expect(prompt.requestId == "req-1")
        #expect(prompt.status == .pending)
        #expect(prompt.serviceName == "Google Calendar")
    }

    @Test("the viewer's own approved result row hydrates the prompt as connected")
    func hydratesConnectedPrompt() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 2)

        let prompt = try #require(try harness.fetchPrompt())
        #expect(prompt.status == .connected)
    }

    @Test("another member's approved result row leaves the viewer's prompt pending")
    func hydrationKeepsViewerPendingAfterOtherMemberApproval() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: approver, status: .approved, sortId: 2)

        let prompt = try #require(try harness.fetchPrompt())
        #expect(prompt.status == .pending)
    }

    @Test("approved result row from the asker leaves the prompt pending")
    func hydrationIgnoresAskerResults() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: asker, status: .approved, sortId: 2)

        let prompt = try #require(try harness.fetchPrompt())
        #expect(prompt.status == .pending)
    }

    @Test("result rows for other requests do not affect the prompt")
    func hydrationJoinsByRequestId() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-other", senderId: harness.currentInboxId, status: .approved, sortId: 2)

        let prompt = try #require(try harness.fetchPrompt())
        #expect(prompt.status == .pending)
    }

    @Test("undecodable request JSON keeps the row hidden")
    func hydrationHidesMalformedRequests() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRawRequestRow(text: "{not json", sortId: 1)

        #expect(try harness.fetchPrompt() == nil)
    }

    @Test("result rows themselves stay hidden in the transcript")
    func resultRowsStayHidden() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertResultRow(requestId: "req-1", senderId: approver, status: .approved, sortId: 1)

        let messages = try harness.fetchMessages()
        #expect(messages.isEmpty)
    }

    // MARK: - Layer agreement (pill derivation vs CapabilityRequestRepository)

    // Both layers share CapabilityConnectPrompt.resolution: the pill shows
    // `.pending` exactly when the repository surfaces that request as the
    // pending picker layout (the tap path). Each test pins both verdicts on
    // the same database so the pill can never look actionable while the tap
    // path would refuse it, or vice versa.

    @Test("the viewer's approval resolves the request in both layers")
    func agreementOnViewerApproval() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 2)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == nil)
    }

    // The multi-member contract: every member sees the pill, and it grays out
    // only for a member who has used it themselves. The harness models user 1
    // as `currentInboxId` and user 2 as `approver`, alongside the agent asker.

    @Test("one member's approval consumes the pill only for that member")
    func otherMemberApprovalKeepsViewerActionable() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: approver, status: .approved, sortId: 2)

        #expect(try harness.fetchPrompt(requestId: "req-1", as: approver)?.status == .connected)
        #expect(try harness.latestPendingRequestId(as: approver) == nil)
        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .pending)
        #expect(try harness.latestPendingRequestId() == "req-1")
    }

    @Test("each member's own approval completes the request for them")
    func bothMembersConnectedAfterBothApprove() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: approver, status: .approved, sortId: 2)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == nil)
        #expect(try harness.fetchPrompt(requestId: "req-1", as: approver)?.status == .connected)
        #expect(try harness.latestPendingRequestId(as: approver) == nil)
    }

    @Test("a denial dismisses the request only for its author")
    func dismissalIsPerViewer() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: approver, status: .denied, sortId: 2)

        #expect(try harness.fetchPrompt(requestId: "req-1", as: approver)?.status == .dismissed)
        #expect(try harness.latestPendingRequestId(as: approver) == nil)
        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .pending)
        #expect(try harness.latestPendingRequestId() == "req-1")

        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == nil)
        #expect(try harness.fetchPrompt(requestId: "req-1", as: approver)?.status == .dismissed)
        #expect(try harness.latestPendingRequestId(as: approver) == nil)
    }

    @Test("asker-authored approval leaves the request open in both layers")
    func agreementOnAskerAuthoredApproval() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: asker, status: .approved, sortId: 2)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .pending)
        #expect(try harness.latestPendingRequestId() == "req-1")
    }

    @Test("asker-authored cancellation cannot kill the request for the room")
    func agreementOnAskerAuthoredCancellation() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: asker, status: .cancelled, sortId: 2)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .pending)
        #expect(try harness.latestPendingRequestId() == "req-1")
    }

    @Test("mixed rows agree: only the viewer's earliest decision counts in both layers")
    func agreementOnMixedMemberRows() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: approver, status: .denied, sortId: 2)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 3)
        try harness.insertResultRow(requestId: "req-1", senderId: approver, status: .approved, sortId: 4)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == nil)
    }

    @Test("the viewer's denial before their approval dismisses in both layers")
    func agreementOnDenialBeforeApproval() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .denied, sortId: 2)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .dismissed)
        #expect(try harness.latestPendingRequestId() == nil)
    }

    @Test("the viewer's approval before their denial connects in both layers")
    func agreementOnApprovalBeforeDenial() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 2)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .denied, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == nil)
    }

    @Test("an asker denial then the viewer's approval connects in both layers")
    func agreementOnAskerDenialThenApproval() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: asker, status: .denied, sortId: 2)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == nil)
    }

    @Test("identical timestamps agree deterministically via the message id tiebreaker")
    func agreementOnIdenticalTimestamps() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        let sharedNs = Int64(harness.now.timeIntervalSince1970 * 1_000_000_000) + 10
        // Same dateNs on both rows; the lower message id ("message-2", the
        // approval) must win in both layers regardless of insertion order.
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .denied, sortId: 3, dateNs: sharedNs)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 2, dateNs: sharedNs)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == nil)
    }

    @Test("non-decision statuses leave the request open in both layers")
    func agreementOnNonDecisionStatuses() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .staleResource, sortId: 2)
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .unknown, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .pending)
        #expect(try harness.latestPendingRequestId() == "req-1")
    }

    @Test("a newer unresolved request supersedes the older one in both layers")
    func agreementOnSupersededRequest() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(requestId: "req-1"), sortId: 1)
        try harness.insertRequestRow(makeRequest(requestId: "req-2"), sortId: 2)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .superseded)
        #expect(try harness.fetchPrompt(requestId: "req-2")?.status == .pending)
        #expect(try harness.latestPendingRequestId() == "req-2")
    }

    @Test("the viewer resolving the newer request hands actionability back to the older one")
    func agreementOnSupersededFlipBack() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(requestId: "req-1"), sortId: 1)
        try harness.insertRequestRow(makeRequest(requestId: "req-2"), sortId: 2)
        try harness.insertResultRow(requestId: "req-2", senderId: harness.currentInboxId, status: .approved, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .pending)
        #expect(try harness.fetchPrompt(requestId: "req-2")?.status == .connected)
        #expect(try harness.latestPendingRequestId() == "req-1")
    }

    @Test("another member resolving the newer request changes nothing for the viewer")
    func agreementOnSupersededHeldByOtherMemberResolution() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.insertRequestRow(makeRequest(requestId: "req-1"), sortId: 1)
        try harness.insertRequestRow(makeRequest(requestId: "req-2"), sortId: 2)
        try harness.insertResultRow(requestId: "req-2", senderId: approver, status: .approved, sortId: 3)

        #expect(try harness.fetchPrompt(requestId: "req-1")?.status == .superseded)
        #expect(try harness.fetchPrompt(requestId: "req-2")?.status == .pending)
        #expect(try harness.latestPendingRequestId() == "req-2")
    }

    // MARK: - Agent DM fixture

    @Test("a pending request in an agent DM derives per-viewer exactly like a group")
    func dmFixtureDerivesPerViewer() throws {
        let harness = try HydrationHarness(asker: asker, approver: approver)
        try harness.dbManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isAgentDm = 1 WHERE id = ?",
                arguments: [harness.conversationId]
            )
        }
        try harness.insertRequestRow(makeRequest(), sortId: 1)
        let pending = try #require(try harness.fetchPrompt())
        #expect(pending.status == .pending)
        // The viewer's own approval resolves it; per-viewer rules are
        // unchanged by the DM classification.
        try harness.insertResultRow(requestId: "req-1", senderId: harness.currentInboxId, status: .approved, sortId: 2)
        let connected = try #require(try harness.fetchPrompt())
        #expect(connected.status == .connected)
    }
}

// MARK: - GRDB harness

private struct HydrationHarness {
    let dbManager: any DatabaseManagerProtocol
    let conversationId: String = "conversation-1"
    let currentInboxId: String = "current-user"
    let asker: String
    let approver: String
    let now: Date = Date()

    init(asker: String, approver: String) throws {
        self.asker = asker
        self.approver = approver
        dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                otherInboxIds: [asker, approver],
                now: now
            )
        }
    }

    func insertRequestRow(_ request: CapabilityRequest, sortId: Int64) throws {
        let json = try JSONEncoder().encode(request)
        try insertRawRequestRow(text: String(decoding: json, as: UTF8.self), sortId: sortId)
    }

    func insertRawRequestRow(text: String, sortId: Int64) throws {
        try insertRow(contentType: .capabilityRequest, senderId: asker, text: text, sortId: sortId)
    }

    func insertResultRow(
        requestId: String,
        senderId: String,
        status: CapabilityRequestResult.Status,
        sortId: Int64,
        dateNs: Int64? = nil
    ) throws {
        let result = CapabilityRequestResult(
            requestId: requestId,
            status: status,
            subject: .calendar,
            capability: .read
        )
        let json = try JSONEncoder().encode(result)
        try insertRow(
            contentType: .capabilityRequestResult,
            senderId: senderId,
            text: String(decoding: json, as: UTF8.self),
            sortId: sortId,
            dateNs: dateNs
        )
    }

    /// `viewer` defaults to `currentInboxId` (user 1's device); passing
    /// another member's inbox id derives the transcript that member's device
    /// would compose, so per-viewer tests can assert both sides of one store.
    func fetchMessages(as viewer: String? = nil) throws -> [AnyMessage] {
        let repository = MessagesRepository(
            dbReader: dbManager.dbReader,
            conversationId: conversationId,
            currentInboxId: viewer ?? currentInboxId
        )
        return try repository.fetchInitial()
    }

    func fetchPrompt() throws -> CapabilityConnectPrompt? {
        try fetchPrompts().first
    }

    func fetchPrompt(requestId: String, as viewer: String? = nil) throws -> CapabilityConnectPrompt? {
        try fetchPrompts(as: viewer).first { $0.requestId == requestId }
    }

    /// The repository half of the layer-agreement assertions: the request the
    /// tap path would open the approval sheet for, nil when none is pending
    /// for the given viewer.
    func latestPendingRequestId(as viewer: String? = nil) throws -> String? {
        let viewerInboxId = viewer ?? currentInboxId
        return try dbManager.dbReader.read { db in
            CapabilityRequestRepository.computeLatestPendingRequest(
                conversationId: conversationId,
                viewerInboxId: viewerInboxId,
                db: db
            )?.requestId
        }
    }

    private func fetchPrompts(as viewer: String? = nil) throws -> [CapabilityConnectPrompt] {
        try fetchMessages(as: viewer).compactMap { anyMessage in
            if case .message(let message, _) = anyMessage,
               case .capabilityConnect(let prompt) = message.content {
                return prompt
            }
            return nil
        }
    }

    private func insertRow(
        contentType: MessageContentType,
        senderId: String,
        text: String,
        sortId: Int64,
        dateNs: Int64? = nil
    ) throws {
        try dbManager.dbWriter.write { db in
            try DBMessage(
                id: "message-\(sortId)",
                clientMessageId: "message-\(sortId)",
                conversationId: conversationId,
                senderId: senderId,
                dateNs: dateNs ?? Int64(now.timeIntervalSince1970 * 1_000_000_000) + sortId,
                date: now,
                sortId: sortId,
                status: .published,
                messageType: .original,
                contentType: contentType,
                text: text,
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)
        }
    }

    private static func seedConversation(
        db: Database,
        conversationId: String,
        currentInboxId: String,
        otherInboxIds: [String],
        now: Date
    ) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        for inboxId in otherInboxIds {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }

        try DBConversation(
            id: conversationId,
            clientConversationId: "client-\(conversationId)",
            inviteTag: "invite-tag-\(conversationId)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: now,
            name: "Test",
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false,
        ).insert(db)

        try ConversationLocalState(
            conversationId: conversationId,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: now,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        for (index, inboxId) in ([currentInboxId] + otherInboxIds).enumerated() {
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: index == 0 ? .superAdmin : .member,
                consent: .allowed,
                createdAt: now,
                invitedByInboxId: nil
            ).insert(db)

            try DBMemberProfile(
                conversationId: conversationId,
                inboxId: inboxId,
                name: "Member \(index)",
                avatar: nil
            ).insert(db)
        }
    }
}
