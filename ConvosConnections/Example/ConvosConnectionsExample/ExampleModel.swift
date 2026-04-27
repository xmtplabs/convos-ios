import ConvosConnections
import ConvosConnectionsScreenTime
import Foundation
import Observation

/// Drives the example app UI. Wraps a `ConnectionsManager` configured with the package's
/// ship-worthy sources (Health, Calendar, Location, Contacts, Photos, Music, Motion,
/// HomeKit, Screen Time) plus the `CalendarDataSink` for write capabilities.
///
/// Exposes two mock conversations per kind so the distinction between iOS authorization
/// (global to the app) and per-conversation enablement (the package's core value) stays
/// visible. For Calendar, also exposes per-capability write toggles and a simulated-agent
/// "create event" button so contributors can see write-side round-trips.
@MainActor
@Observable
final class ExampleModel {
    let manager: ConnectionsManager
    let messageStore: MockMessageStore
    let confirmationHandler: ExampleConfirmationHandler

    private(set) var kinds: [ConnectionKind] = []
    private(set) var statuses: [ConnectionKind: ConnectionAuthorizationStatus] = [:]
    private(set) var detailsByKind: [ConnectionKind: [AuthorizationDetail]] = [:]
    private(set) var enabledConversationIds: Set<String> = []
    private(set) var messagesByConversation: [String: [MockMessageStore.Message]] = [:]
    /// Per-(kind, capability, conversationId) enablement flags.
    private(set) var capabilityEnablement: [CapabilityKey: Bool] = [:]
    /// Per-(kind, conversationId) always-confirm flags.
    private(set) var alwaysConfirmByConversation: [String: Bool] = [:]
    private(set) var invocationLog: [RecordedInvocation] = []
    /// Write capabilities available per kind, derived from sink action schemas.
    private(set) var writeCapabilitiesByKind: [ConnectionKind: [ConnectionCapability]] = [:]
    private(set) var lastError: String?

    struct CapabilityKey: Hashable, Sendable {
        let kind: ConnectionKind
        let capability: ConnectionCapability
        let conversationId: String
    }

    init() {
        let messageStore = MockMessageStore()
        let enablementStore = UserDefaultsEnablementStore()
        let confirmationHandler = ExampleConfirmationHandler()
        let sources: [DataSource] = [
            HealthDataSource(),
            CalendarDataSource(),
            LocationDataSource(),
            ContactsDataSource(),
            PhotosDataSource(),
            MusicDataSource(),
            MotionDataSource(),
            HomeDataSource(),
            ScreenTimeDataSource(),
        ]
        let sinks: [DataSink] = [
            CalendarDataSink(),
            ContactsDataSink(),
            HomeKitDataSink(),
            PhotosDataSink(),
            HealthDataSink(),
            ScreenTimeDataSink(),
            MusicDataSink(),
        ]
        self.messageStore = messageStore
        self.confirmationHandler = confirmationHandler
        self.manager = ConnectionsManager(
            sources: sources,
            sinks: sinks,
            store: enablementStore,
            delivery: messageStore
        )
        Task { [manager = self.manager, handler = confirmationHandler] in
            await manager.setConfirmationHandler(handler)
        }
    }

    func conversations(for kind: ConnectionKind) -> [MockConversation] {
        MockConversationCatalog.conversations(for: kind)
    }

    func writeCapabilities(for kind: ConnectionKind) -> [ConnectionCapability] {
        writeCapabilitiesByKind[kind] ?? []
    }

    func toggle(conversation: MockConversation, enabled: Bool) async {
        lastError = nil
        let kind = conversation.kind
        await manager.setEnabled(enabled, kind: kind, conversationId: conversation.id)

        if enabled {
            do {
                let status = await manager.authorizationStatus(for: kind)
                if status == .notDetermined {
                    _ = try await manager.requestAuthorization(for: kind)
                }
                try await manager.startSource(kind: kind)
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            let remaining = await manager.enabledConversationIds(for: kind)
            if remaining.isEmpty {
                await manager.stopSource(kind: kind)
            }
        }
        await refresh()
    }

    func toggleCapability(
        _ capability: ConnectionCapability,
        enabled: Bool,
        conversation: MockConversation
    ) async {
        lastError = nil
        await manager.setEnabled(enabled, kind: conversation.kind, capability: capability, conversationId: conversation.id)
        await refresh()
    }

    func toggleAlwaysConfirm(_ enabled: Bool, conversation: MockConversation) async {
        await manager.setAlwaysConfirmWrites(enabled, kind: conversation.kind, conversationId: conversation.id)
        await refresh()
    }

    func requestAuthorization(for kind: ConnectionKind) async {
        lastError = nil
        do {
            _ = try await manager.requestAuthorization(for: kind)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Simulate an agent creating a calendar event. The agent in the real app would emit a
    /// `ConnectionInvocation` over XMTP; here we construct one inline and feed it to
    /// `ConnectionsManager.handleInvocation`. The manager's gating and fan-out applies
    /// identically to real XMTP-sourced invocations.
    func simulateAgentCreateEvent(for conversation: MockConversation) async {
        lastError = nil
        guard conversation.kind == .calendar else {
            lastError = "Agent simulation only implemented for Calendar."
            return
        }

        let now = Date()
        let startDate = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
        let endDate = Calendar.current.date(byAdding: .hour, value: 2, to: now) ?? now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startISO = formatter.string(from: startDate)
        let endISO = formatter.string(from: endDate)

        let invocation = ConnectionInvocation(
            invocationId: "example-\(UUID().uuidString.prefix(8))",
            kind: .calendar,
            action: ConnectionAction(
                name: "create_event",
                arguments: [
                    "title": .string("Agent-created event"),
                    "startDate": .iso8601DateTime(startISO),
                    "endDate": .iso8601DateTime(endISO),
                    "timeZone": .string(TimeZone.current.identifier),
                    "location": .string("Anywhere"),
                    "notes": .string("Created by the example app via simulateAgentCreateEvent."),
                ]
            )
        )
        _ = await manager.handleInvocation(invocation, from: conversation.id)
        await refresh()
    }

    /// Simulate an agent pausing music playback.
    func simulateAgentPauseMusic(for conversation: MockConversation) async {
        lastError = nil
        guard conversation.kind == .music else {
            lastError = "Agent simulation only implemented for Music here."
            return
        }
        let invocation = ConnectionInvocation(
            invocationId: "example-\(UUID().uuidString.prefix(8))",
            kind: .music,
            action: ConnectionAction(name: "pause", arguments: [:])
        )
        _ = await manager.handleInvocation(invocation, from: conversation.id)
        await refresh()
    }

    /// Simulate an agent logging a glass of water to HealthKit.
    func simulateAgentLogWater(for conversation: MockConversation) async {
        lastError = nil
        guard conversation.kind == .health else {
            lastError = "Agent simulation only implemented for Health here."
            return
        }
        let invocation = ConnectionInvocation(
            invocationId: "example-\(UUID().uuidString.prefix(8))",
            kind: .health,
            action: ConnectionAction(
                name: "log_water",
                arguments: [
                    "quantity": .double(8),
                    "unit": .enumValue("oz"),
                ]
            )
        )
        _ = await manager.handleInvocation(invocation, from: conversation.id)
        await refresh()
    }

    /// Simulate an agent saving a small red-pixel image to the photo library.
    func simulateAgentSaveImage(for conversation: MockConversation) async {
        lastError = nil
        guard conversation.kind == .photos else {
            lastError = "Agent simulation only implemented for Photos here."
            return
        }
        // 10x10 solid red PNG, base64-encoded.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAH0lEQVR4nGP8z8DwnwEJMDGgASoJsDCgASoJsKAbAAAoIgMBl6Qn2wAAAABJRU5ErkJggg=="
        let invocation = ConnectionInvocation(
            invocationId: "example-\(UUID().uuidString.prefix(8))",
            kind: .photos,
            action: ConnectionAction(
                name: "save_image",
                arguments: [
                    "imageData": .string(base64),
                    "isFavorite": .bool(false),
                ]
            )
        )
        _ = await manager.handleInvocation(invocation, from: conversation.id)
        await refresh()
    }

    /// Simulate an agent creating a contact. Uses the same gating pipeline.
    func simulateAgentCreateContact(for conversation: MockConversation) async {
        lastError = nil
        guard conversation.kind == .contacts else {
            lastError = "Agent simulation only implemented for Contacts here."
            return
        }
        let stamp = Int(Date().timeIntervalSince1970) % 10000
        let invocation = ConnectionInvocation(
            invocationId: "example-\(UUID().uuidString.prefix(8))",
            kind: .contacts,
            action: ConnectionAction(
                name: "create_contact",
                arguments: [
                    "givenName": .string("Convos"),
                    "familyName": .string("Agent #\(stamp)"),
                    "organization": .string("Convos Test"),
                    "email": .string("agent+\(stamp)@convos.test"),
                    "phone": .string("+15555550\(String(format: "%03d", stamp % 1000))"),
                    "note": .string("Created by the example app via simulateAgentCreateContact."),
                ]
            )
        )
        _ = await manager.handleInvocation(invocation, from: conversation.id)
        await refresh()
    }

    func simulateSnapshot(for conversation: MockConversation) async {
        lastError = nil
        do {
            switch conversation.kind {
            case .health:
                if let source = await manager.source(for: .health) as? HealthDataSource {
                    let payload = try await source.snapshotLast24Hours()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .health, body: .health(payload)),
                        to: conversation.id
                    )
                }
            case .calendar:
                if let source = await manager.source(for: .calendar) as? CalendarDataSource {
                    let payload = try await source.snapshotCurrentWindow()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .calendar, body: .calendar(payload)),
                        to: conversation.id
                    )
                }
            case .location:
                let placeholder = LocationPayload(
                    summary: "Simulated event (real Location events only fire on movement)",
                    events: []
                )
                try await messageStore.deliver(
                    ConnectionPayload(source: .location, body: .location(placeholder)),
                    to: conversation.id
                )
            case .contacts:
                if let source = await manager.source(for: .contacts) as? ContactsDataSource {
                    let payload = try await source.snapshotCurrent()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .contacts, body: .contacts(payload)),
                        to: conversation.id
                    )
                }
            case .photos:
                if let source = await manager.source(for: .photos) as? PhotosDataSource {
                    let payload = try await source.snapshotCurrent()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .photos, body: .photos(payload)),
                        to: conversation.id
                    )
                }
            case .music:
                if let source = await manager.source(for: .music) as? MusicDataSource {
                    let payload = await source.snapshotCurrent()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .music, body: .music(payload)),
                        to: conversation.id
                    )
                }
            case .motion:
                if let source = await manager.source(for: .motion) as? MotionDataSource {
                    let payload = try await source.snapshotCurrent()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .motion, body: .motion(payload)),
                        to: conversation.id
                    )
                }
            case .homeKit:
                if let source = await manager.source(for: .homeKit) as? HomeDataSource {
                    let payload = await source.snapshotCurrent()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .homeKit, body: .homeKit(payload)),
                        to: conversation.id
                    )
                }
            case .screenTime:
                if let source = await manager.source(for: .screenTime) as? ScreenTimeDataSource {
                    let payload = await source.snapshotCurrent()
                    try await messageStore.deliver(
                        ConnectionPayload(source: .screenTime, body: .screenTime(payload)),
                        to: conversation.id
                    )
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func clearMessages(for conversation: MockConversation) async {
        await messageStore.clearMessages(for: conversation.id)
        await refresh()
    }

    func clearInvocationLog() async {
        await manager.clearRecentInvocationLog()
        await refresh()
    }

    func refresh() async {
        let kinds = manager.availableKinds()
        var statuses: [ConnectionKind: ConnectionAuthorizationStatus] = [:]
        var details: [ConnectionKind: [AuthorizationDetail]] = [:]
        var enabled: Set<String> = []
        var messages: [String: [MockMessageStore.Message]] = [:]
        var capabilityState: [CapabilityKey: Bool] = [:]
        var alwaysConfirmState: [String: Bool] = [:]
        var capabilitiesByKind: [ConnectionKind: [ConnectionCapability]] = [:]
        for kind in kinds {
            statuses[kind] = await manager.authorizationStatus(for: kind)
            details[kind] = await manager.authorizationDetails(for: kind)
            let schemas = await manager.actionSchemas(for: kind)
            let capabilityOrder: [ConnectionCapability] = [.writeCreate, .writeUpdate, .writeDelete]
            let writeCapabilities = capabilityOrder.filter { capability in
                schemas.contains { $0.capability == capability }
            }
            capabilitiesByKind[kind] = writeCapabilities
            let readEnabled = await manager.enabledConversationIds(for: kind)
            for conversationId in readEnabled {
                enabled.insert(conversationId)
            }
            for conversation in MockConversationCatalog.conversations(for: kind) {
                messages[conversation.id] = await messageStore.messages(for: conversation.id)
                for capability in writeCapabilities {
                    let isOn = await manager.isEnabled(
                        kind,
                        capability: capability,
                        conversationId: conversation.id
                    )
                    capabilityState[CapabilityKey(kind: kind, capability: capability, conversationId: conversation.id)] = isOn
                }
                if !writeCapabilities.isEmpty {
                    let confirm = await manager.alwaysConfirmWrites(kind: kind, conversationId: conversation.id)
                    alwaysConfirmState[conversation.id] = confirm
                }
            }
        }
        self.kinds = kinds
        self.statuses = statuses
        self.detailsByKind = details
        self.enabledConversationIds = enabled
        self.messagesByConversation = messages
        self.capabilityEnablement = capabilityState
        self.alwaysConfirmByConversation = alwaysConfirmState
        self.writeCapabilitiesByKind = capabilitiesByKind
        self.invocationLog = await manager.recentInvocationLog()
    }
}
