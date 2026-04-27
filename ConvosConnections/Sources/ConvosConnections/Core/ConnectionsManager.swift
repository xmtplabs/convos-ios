import Foundation

/// Orchestrates the lifecycle of data sources and sinks, consults the `EnablementStore` to
/// decide which conversations each payload should go to, routes inbound invocations from
/// agents to the right sink, and forwards payloads and invocation results to the host's
/// `ConnectionDelivering` adapter.
///
/// The manager is an `actor` so internal state (started sources, recent-payload log,
/// recent-invocation log) stays race-free across emit callbacks from sources and inbound
/// invocations from multiple conversations.
public actor ConnectionsManager {
    private let sources: [ConnectionKind: DataSource]
    private let sinks: [ConnectionKind: DataSink]
    private let store: EnablementStore
    private let delivery: ConnectionDelivering
    private let deliveryObserver: ConnectionDeliveryObserver?
    private var confirmationHandler: ConfirmationHandling?
    private let recentPayloadLimit: Int
    private let recentInvocationLimit: Int

    private var started: Set<ConnectionKind> = []
    private var recentPayloads: [RecordedPayload] = []
    private var recentInvocations: [RecordedInvocation] = []

    public init(
        sources: [DataSource],
        sinks: [DataSink] = [],
        store: EnablementStore,
        delivery: ConnectionDelivering,
        deliveryObserver: ConnectionDeliveryObserver? = nil,
        confirmationHandler: ConfirmationHandling? = nil,
        recentPayloadLimit: Int = 100,
        recentInvocationLimit: Int = 100
    ) {
        var sourcesByKind: [ConnectionKind: DataSource] = [:]
        for source in sources {
            sourcesByKind[source.kind] = source
        }
        var sinksByKind: [ConnectionKind: DataSink] = [:]
        for sink in sinks {
            sinksByKind[sink.kind] = sink
        }
        self.sources = sourcesByKind
        self.sinks = sinksByKind
        self.store = store
        self.delivery = delivery
        self.deliveryObserver = deliveryObserver
        self.confirmationHandler = confirmationHandler
        self.recentPayloadLimit = recentPayloadLimit
        self.recentInvocationLimit = recentInvocationLimit
    }

    // MARK: - Available sources / sinks

    public nonisolated func availableKinds() -> [ConnectionKind] {
        Array(Set(sources.keys).union(sinks.keys)).sorted(by: { $0.rawValue < $1.rawValue })
    }

    public func source(for kind: ConnectionKind) -> DataSource? {
        sources[kind]
    }

    public func sink(for kind: ConnectionKind) -> DataSink? {
        sinks[kind]
    }

    public func actionSchemas(for kind: ConnectionKind) async -> [ActionSchema] {
        guard let sink = sinks[kind] else { return [] }
        return await sink.actionSchemas()
    }

    public func allActionSchemas() async -> [ActionSchema] {
        var all: [ActionSchema] = []
        for sink in sinks.values {
            let schemas = await sink.actionSchemas()
            all.append(contentsOf: schemas)
        }
        return all.sorted(by: { $0.id < $1.id })
    }

    // MARK: - Authorization

    public func authorizationStatus(for kind: ConnectionKind) async -> ConnectionAuthorizationStatus {
        if let source = sources[kind] {
            return await source.authorizationStatus()
        }
        if let sink = sinks[kind] {
            return await sink.authorizationStatus()
        }
        return .unavailable
    }

    @discardableResult
    public func requestAuthorization(for kind: ConnectionKind) async throws -> ConnectionAuthorizationStatus {
        if let source = sources[kind] {
            return try await source.requestAuthorization()
        }
        if let sink = sinks[kind] {
            return try await sink.requestAuthorization()
        }
        return .unavailable
    }

    public func authorizationDetails(for kind: ConnectionKind) async -> [AuthorizationDetail] {
        if let source = sources[kind] {
            return await source.authorizationDetails()
        }
        return []
    }

    // MARK: - Read enablement (capability = .read)

    public func isEnabled(_ kind: ConnectionKind, conversationId: String) async -> Bool {
        await store.isEnabled(kind: kind, capability: .read, conversationId: conversationId)
    }

    public func setEnabled(_ enabled: Bool, kind: ConnectionKind, conversationId: String) async {
        await store.setEnabled(enabled, kind: kind, capability: .read, conversationId: conversationId)
    }

    public func enabledConversationIds(for kind: ConnectionKind) async -> [String] {
        await store.conversationIds(enabledFor: kind, capability: .read)
    }

    public func allEnablements() async -> [Enablement] {
        await store.allEnablements()
    }

    // MARK: - Per-capability enablement

    public func isEnabled(_ kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async -> Bool {
        await store.isEnabled(kind: kind, capability: capability, conversationId: conversationId)
    }

    public func setEnabled(_ enabled: Bool, kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async {
        await store.setEnabled(enabled, kind: kind, capability: capability, conversationId: conversationId)
    }

    public func enabledConversationIds(for kind: ConnectionKind, capability: ConnectionCapability) async -> [String] {
        await store.conversationIds(enabledFor: kind, capability: capability)
    }

    // MARK: - Always-confirm toggle

    public func alwaysConfirmWrites(kind: ConnectionKind, conversationId: String) async -> Bool {
        await store.alwaysConfirmWrites(kind: kind, conversationId: conversationId)
    }

    public func setAlwaysConfirmWrites(_ alwaysConfirm: Bool, kind: ConnectionKind, conversationId: String) async {
        await store.setAlwaysConfirmWrites(alwaysConfirm, kind: kind, conversationId: conversationId)
    }

    // MARK: - Confirmation handler

    public func setConfirmationHandler(_ handler: ConfirmationHandling?) {
        confirmationHandler = handler
    }

    // MARK: - Source lifecycle

    public func start() async throws {
        let enablements = await store.allEnablements()
        let kindsNeedingStart = Set(enablements.filter { $0.capability == .read }.map(\.kind))
        for kind in kindsNeedingStart {
            try await startSource(kind: kind)
        }
    }

    public func startSource(kind: ConnectionKind) async throws {
        guard !started.contains(kind) else { return }
        guard let source = sources[kind] else { return }
        try await source.start(emit: { [weak self] payload in
            guard let self else { return }
            Task { await self.handleEmittedPayload(payload) }
        })
        started.insert(kind)
    }

    public func stop() async {
        for kind in started {
            if let source = sources[kind] {
                await source.stop()
            }
        }
        started.removeAll()
    }

    public func stopSource(kind: ConnectionKind) async {
        guard started.contains(kind) else { return }
        if let source = sources[kind] {
            await source.stop()
        }
        started.remove(kind)
    }

    // MARK: - Invocation routing

    /// Main entry point for inbound agent invocations.
    ///
    /// Routing order:
    /// 1. Sink lookup by `invocation.kind`. Missing → `unknownAction`.
    /// 2. Action-schema lookup by `invocation.action.name`. Missing → `unknownAction`.
    /// 3. Capability gate via `EnablementStore.isEnabled(kind, capability, conversationId)`.
    ///    False → `capabilityNotEnabled`.
    /// 4. Always-confirm gate: if `alwaysConfirmWrites` is true for the `(kind, conv)` pair,
    ///    call the installed `ConfirmationHandling.confirm(request)`. Missing handler or
    ///    `.cannotPresent` → `requiresConfirmation`. `.denied` → `authorizationDenied`.
    /// 5. Re-check capability after confirmation (user may have revoked mid-prompt).
    ///    False → `capabilityRevoked`.
    /// 6. `sink.invoke(invocation)` — sink owns final status (success vs. executionFailed).
    /// 7. Append to `recentInvocations` log.
    /// 8. `delivery.deliver(result, to: conversationId)` — errors surface via
    ///    `deliveryObserver.connectionInvocation(didFailDelivery:)` and are stored in the
    ///    log entry's `resultDeliveryError`, but do not bubble up.
    ///
    /// Never throws: all failure modes surface through the returned/delivered result.
    @discardableResult
    public func handleInvocation(_ invocation: ConnectionInvocation, from conversationId: String) async -> ConnectionInvocationResult {
        let result = await routeInvocation(invocation, from: conversationId)
        var deliveryError: String?
        do {
            try await delivery.deliver(result, to: conversationId)
            await deliveryObserver?.connectionInvocation(didDeliver: result, conversationId: conversationId)
        } catch {
            deliveryError = error.localizedDescription
            await deliveryObserver?.connectionInvocation(didFailDelivery: error, result: result, conversationId: conversationId)
        }
        appendInvocationRecord(
            RecordedInvocation(
                invocation: invocation,
                conversationId: conversationId,
                result: result,
                resultDeliveryError: deliveryError
            )
        )
        return result
    }

    private func routeInvocation(_ invocation: ConnectionInvocation, from conversationId: String) async -> ConnectionInvocationResult {
        guard let sink = sinks[invocation.kind] else {
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "No sink registered for \(invocation.kind.rawValue)."
            )
        }
        let schemas = await sink.actionSchemas()
        guard let schema = schemas.first(where: { $0.actionName == invocation.action.name }) else {
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "Action '\(invocation.action.name)' is not supported by the \(invocation.kind.rawValue) sink."
            )
        }
        let capability = schema.capability
        let enabledBefore = await store.isEnabled(kind: invocation.kind, capability: capability, conversationId: conversationId)
        guard enabledBefore else {
            return Self.makeResult(
                for: invocation,
                status: .capabilityNotEnabled,
                errorMessage: "Capability \(capability.rawValue) is not enabled for this conversation."
            )
        }

        if await store.alwaysConfirmWrites(kind: invocation.kind, conversationId: conversationId) {
            let decision = await requestConfirmation(
                invocation: invocation,
                conversationId: conversationId,
                capability: capability
            )
            switch decision {
            case .approved:
                break
            case .denied:
                return Self.makeResult(
                    for: invocation,
                    status: .authorizationDenied,
                    errorMessage: "User denied the invocation."
                )
            case .cannotPresent:
                return Self.makeResult(
                    for: invocation,
                    status: .requiresConfirmation,
                    errorMessage: "Confirmation required but cannot be presented (app backgrounded or no handler installed)."
                )
            }

            let enabledAfter = await store.isEnabled(kind: invocation.kind, capability: capability, conversationId: conversationId)
            guard enabledAfter else {
                return Self.makeResult(
                    for: invocation,
                    status: .capabilityRevoked,
                    errorMessage: "Capability was revoked during confirmation."
                )
            }
        }

        return await sink.invoke(invocation)
    }

    private func requestConfirmation(
        invocation: ConnectionInvocation,
        conversationId: String,
        capability: ConnectionCapability
    ) async -> ConfirmationDecision {
        guard let handler = confirmationHandler else { return .cannotPresent }
        let request = ConfirmationRequest(
            invocationId: invocation.invocationId,
            conversationId: conversationId,
            kind: invocation.kind,
            capability: capability,
            actionName: invocation.action.name,
            arguments: invocation.action.arguments,
            humanSummary: Self.humanSummary(for: invocation)
        )
        return await handler.confirm(request)
    }

    private static func humanSummary(for invocation: ConnectionInvocation) -> String {
        let argsPreview = invocation.action.arguments
            .sorted(by: { $0.key < $1.key })
            .prefix(3)
            .map { "\($0.key)=\(describe($0.value))" }
            .joined(separator: ", ")
        if argsPreview.isEmpty {
            return "\(invocation.kind.displayName): \(invocation.action.name)"
        }
        return "\(invocation.kind.displayName): \(invocation.action.name) (\(argsPreview))"
    }

    private static func describe(_ value: ArgumentValue) -> String {
        switch value {
        case .string(let v): return "\"\(v)\""
        case .bool(let v): return String(v)
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .date(let v): return String(describing: v)
        case .iso8601DateTime(let v): return v
        case .enumValue(let v): return v
        case .array(let v): return "[\(v.count) items]"
        case .null: return "null"
        }
    }

    private static func makeResult(
        for invocation: ConnectionInvocation,
        status: ConnectionInvocationResult.Status,
        errorMessage: String? = nil,
        result: [String: ArgumentValue] = [:]
    ) -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: status,
            result: result,
            errorMessage: errorMessage
        )
    }

    // MARK: - Recent payload log

    public func recentPayloadLog() -> [RecordedPayload] {
        recentPayloads
    }

    public func clearRecentPayloadLog() {
        recentPayloads.removeAll()
    }

    // MARK: - Recent invocation log

    public func recentInvocationLog() -> [RecordedInvocation] {
        recentInvocations
    }

    public func clearRecentInvocationLog() {
        recentInvocations.removeAll()
    }

    // MARK: - Emit handling

    private func handleEmittedPayload(_ payload: ConnectionPayload) async {
        let conversationIds = await store.conversationIds(enabledFor: payload.source, capability: .read)
        let record = RecordedPayload(
            payload: payload,
            fanOutConversationIds: conversationIds,
            receivedAt: Date()
        )
        appendRecord(record)
        for conversationId in conversationIds {
            do {
                try await delivery.deliver(payload, to: conversationId)
                await deliveryObserver?.connectionDelivery(didSucceed: payload, conversationId: conversationId)
            } catch {
                await deliveryObserver?.connectionDelivery(didFail: error, payload: payload, conversationId: conversationId)
            }
        }
    }

    private func appendRecord(_ record: RecordedPayload) {
        recentPayloads.append(record)
        if recentPayloads.count > recentPayloadLimit {
            let overflow = recentPayloads.count - recentPayloadLimit
            recentPayloads.removeFirst(overflow)
        }
    }

    private func appendInvocationRecord(_ record: RecordedInvocation) {
        recentInvocations.append(record)
        if recentInvocations.count > recentInvocationLimit {
            let overflow = recentInvocations.count - recentInvocationLimit
            recentInvocations.removeFirst(overflow)
        }
    }
}

/// A recent payload and the conversations it was fanned out to. Used by the debug view.
public struct RecordedPayload: Sendable, Identifiable, Equatable {
    public let payload: ConnectionPayload
    public let fanOutConversationIds: [String]
    public let receivedAt: Date

    public var id: UUID { payload.id }

    public init(payload: ConnectionPayload, fanOutConversationIds: [String], receivedAt: Date) {
        self.payload = payload
        self.fanOutConversationIds = fanOutConversationIds
        self.receivedAt = receivedAt
    }
}

/// A recent invocation, its result, and any delivery failure. Used by the debug view.
public struct RecordedInvocation: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let invocation: ConnectionInvocation
    public let conversationId: String
    public let result: ConnectionInvocationResult
    public let resultDeliveryError: String?
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        invocation: ConnectionInvocation,
        conversationId: String,
        result: ConnectionInvocationResult,
        resultDeliveryError: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.invocation = invocation
        self.conversationId = conversationId
        self.result = result
        self.resultDeliveryError = resultDeliveryError
        self.recordedAt = recordedAt
    }
}
