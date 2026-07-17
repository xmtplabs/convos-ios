import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing

@Suite("Connection event branding")
struct ConnectionEventBrandingTests {
    @Test("granted events format as a sender-actor 'connected <Service>' line")
    func grantedUsesMessageSenderActor() {
        let summary = ConnectionMessageSummaryFormatter.eventSummary(
            ConnectionEvent(
                providerId: "composio.googlecalendar",
                action: .granted,
                capability: .read,
                grantedToInboxId: "agent-inbox"
            )
        )
        #expect(summary.text == "connected Google Calendar")
        #expect(summary.actor == .messageSender)
        #expect(summary.outcome == .success)
        #expect(summary.icon == .calendar)
        #expect(summary.providerId == "composio.googlecalendar")
    }

    @Test("granted device events brand with the device spec name")
    func grantedDeviceBranding() {
        let summary = ConnectionMessageSummaryFormatter.eventSummary(
            ConnectionEvent(providerId: "device.health", action: .granted)
        )
        #expect(summary.text == "connected Apple Health")
        #expect(summary.actor == .messageSender)
    }

    @Test("granted events for unknown providers fall back to a generic phrase")
    func grantedUnknownProviderFallback() {
        let summary = ConnectionMessageSummaryFormatter.eventSummary(
            ConnectionEvent(providerId: "mystery.service", action: .granted)
        )
        #expect(summary.text == "connected a service")
        #expect(summary.icon == .generic)
    }

    @Test("revoked events keep the agent-actor phrasing")
    func revokedUnchanged() {
        let summary = ConnectionMessageSummaryFormatter.eventSummary(
            ConnectionEvent(
                providerId: "composio.googlecalendar",
                action: .revoked,
                capability: .read,
                grantedToInboxId: "agent-inbox"
            )
        )
        #expect(summary.actor == .grantedAgent)
        #expect(summary.providerId == "composio.googlecalendar")
    }

    @Test("summaries persisted before the providerId field still decode")
    func legacySummaryDecodes() throws {
        let legacyJSON = #"{"text":"can read calendar events","outcome":"success","icon":"calendar","actor":"granted_agent","grantedToInboxId":"agent-inbox"}"#
        let summary = try JSONDecoder().decode(ConnectionEventSummary.self, from: Data(legacyJSON.utf8))
        #expect(summary.providerId == nil)
        #expect(summary.text == "can read calendar events")
    }

    @Test("processor resolves the sender actor to You for the granter's own device")
    func processorResolvesYou() throws {
        let summary = ConnectionMessageSummaryFormatter.eventSummary(
            ConnectionEvent(providerId: "composio.googlecalendar", action: .granted, grantedToInboxId: "agent-inbox")
        )
        let sender = ConversationMember.mock(isCurrentUser: true)
        let items = MessagesListProcessor.process([
            .message(Message(
                id: "event-1",
                sender: sender,
                source: .outgoing,
                status: .published,
                content: .connectionEvent(summary: summary),
                date: Date(),
                reactions: []
            ), .existing),
        ])
        let resolved = try #require(items.compactMap { item -> ConnectionEventSummary? in
            if case .connectionEvent(_, let summary, _) = item { return summary }
            return nil
        }.first)
        #expect(resolved.text == "You connected Google Calendar")
        #expect(resolved.providerId == "composio.googlecalendar")
    }

    @Test("processor resolves the sender actor to the member display name elsewhere")
    func processorResolvesDisplayName() throws {
        let summary = ConnectionMessageSummaryFormatter.eventSummary(
            ConnectionEvent(providerId: "composio.googlecalendar", action: .granted, grantedToInboxId: "agent-inbox")
        )
        let sender = ConversationMember.mock(isCurrentUser: false, name: "Louis")
        let items = MessagesListProcessor.process([
            .message(Message(
                id: "event-1",
                sender: sender,
                source: .incoming,
                status: .published,
                content: .connectionEvent(summary: summary),
                date: Date(),
                reactions: []
            ), .existing),
        ])
        let resolved = try #require(items.compactMap { item -> ConnectionEventSummary? in
            if case .connectionEvent(_, let summary, _) = item { return summary }
            return nil
        }.first)
        #expect(resolved.text == "Louis connected Google Calendar")
    }

    @Test("processor emits a capability connect item with the asker's live name")
    func processorEmitsCapabilityConnectItem() throws {
        let prompt = CapabilityConnectPrompt(
            requestId: "req-1",
            askerInboxId: "agent-inbox",
            serviceName: "Google Calendar",
            serviceId: "googlecalendar",
            icon: .calendar,
            status: .pending
        )
        let sender = ConversationMember.mock(isCurrentUser: false, name: "Stale Snapshot")
        let items = MessagesListProcessor.process(
            [
                .message(Message(
                    id: "request-1",
                    sender: sender,
                    source: .incoming,
                    status: .published,
                    content: .capabilityConnect(prompt: prompt),
                    date: Date(),
                    reactions: []
                ), .existing),
            ],
            memberProfiles: [
                "agent-inbox": MemberProfileInfo(
                    inboxId: "agent-inbox",
                    conversationId: "conversation-1",
                    name: "Assistant",
                    avatar: nil
                ),
            ]
        )
        guard case .capabilityConnect(let id, let resolvedPrompt, let agentName, _)? = items.first(where: {
            if case .capabilityConnect = $0 { return true }
            return false
        }) else {
            Issue.record("Expected a capabilityConnect item")
            return
        }
        #expect(id == "request-1")
        #expect(resolvedPrompt == prompt)
        #expect(agentName == "Assistant")
    }

    @Test("capability connect agent name falls back to the sender snapshot")
    func processorAgentNameFallsBackToSender() throws {
        let prompt = CapabilityConnectPrompt(
            requestId: "req-1",
            askerInboxId: "agent-inbox",
            serviceName: "Google Calendar",
            serviceId: "googlecalendar",
            icon: .calendar,
            status: .pending
        )
        let sender = ConversationMember.mock(isCurrentUser: false, name: "Agent Snapshot")
        let items = MessagesListProcessor.process([
            .message(Message(
                id: "request-1",
                sender: sender,
                source: .incoming,
                status: .published,
                content: .capabilityConnect(prompt: prompt),
                date: Date(),
                reactions: []
            ), .existing),
        ])
        guard case .capabilityConnect(_, _, let agentName, _)? = items.first(where: {
            if case .capabilityConnect = $0 { return true }
            return false
        }) else {
            Issue.record("Expected a capabilityConnect item")
            return
        }
        #expect(agentName == "Agent Snapshot")
    }
}
