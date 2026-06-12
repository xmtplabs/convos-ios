import ConvosConnections
import Foundation

/// Render model for a `capability_request` row in the transcript: the centered
/// "<Agent> wants to connect" caption plus the tappable service pill.
///
/// Built at compose time. `status` is derived by joining
/// `capability_request_result` rows on `requestId` (same shape as the
/// reaction join on `sourceMessageId`) — the request row itself is never
/// edited, so the pill stays in history and flips state on every member's
/// device as result rows sync in.
public struct CapabilityConnectPrompt: Hashable, Codable, Sendable {
    public enum Status: String, Hashable, Codable, Sendable {
        /// No validated result row resolves the request yet and it is the
        /// conversation's latest unresolved ask — tapping opens the approval
        /// sheet.
        case pending
        /// An approved result row landed (from any member's device).
        case connected
        /// A denied or cancelled result row landed and no approval exists.
        case dismissed
        /// Still unresolved, but a newer unresolved request has taken over as
        /// the conversation's single actionable ask. Rendered inert; flips
        /// back to `.pending` if the newer request resolves first.
        case superseded
    }

    /// One `capability_request_result` row reduced to what status derivation
    /// needs: who sent it and what they decided.
    public struct ResultRecord: Hashable, Sendable {
        public let senderId: String
        public let status: CapabilityRequestResult.Status

        public init(senderId: String, status: CapabilityRequestResult.Status) {
            self.senderId = senderId
            self.status = status
        }
    }

    public let requestId: String
    public let askerInboxId: String
    /// Brand label for the pill ("Google Calendar"). Resolved from the
    /// request's preferred providers, falling back to the subject name.
    public let serviceName: String
    /// Cloud service slug ("googlecalendar") when the request targets a
    /// `composio.*` provider. The app maps it to a branded icon asset;
    /// nil falls back to the `icon` symbol.
    public let serviceId: String?
    public let icon: ConnectionEventSummary.Icon
    public let status: Status

    public init(
        requestId: String,
        askerInboxId: String,
        serviceName: String,
        serviceId: String?,
        icon: ConnectionEventSummary.Icon,
        status: Status
    ) {
        self.requestId = requestId
        self.askerInboxId = askerInboxId
        self.serviceName = serviceName
        self.serviceId = serviceId
        self.icon = icon
        self.status = status
    }
}

public extension CapabilityConnectPrompt {
    /// `isLatestUnresolvedRequest`: whether this request is the one
    /// `CapabilityRequestRepository.computeLatestPendingRequest` would surface
    /// — i.e. the conversation's single actionable ask. Unresolved requests
    /// that aren't it render `.superseded` instead of `.pending`, so the pill
    /// is never tappable-looking while the tap path would refuse it.
    static func make(
        request: CapabilityRequest,
        results: [ResultRecord],
        isLatestUnresolvedRequest: Bool
    ) -> CapabilityConnectPrompt {
        let preferredProviderId = request.preferredProviders?.first
        return CapabilityConnectPrompt(
            requestId: request.requestId,
            askerInboxId: request.askerInboxId,
            serviceName: serviceName(forPreferredProvider: preferredProviderId, subject: request.subject),
            serviceId: preferredProviderId?.cloudServiceId,
            icon: icon(forPreferredProvider: preferredProviderId, subject: request.subject),
            status: displayStatus(
                results: results,
                askerInboxId: request.askerInboxId,
                isLatestUnresolvedRequest: isLatestUnresolvedRequest
            )
        )
    }

    /// THE single definition of a "resolving" result, shared by the display
    /// derivation (pill status) and `CapabilityRequestRepository` (pending
    /// picker layout, i.e. the tap path) — both layers must always agree on
    /// whether a request is still open.
    ///
    /// First responder wins: one capability request is one connection ask for
    /// the whole conversation. The first validated result resolves it for
    /// every member — on approval the pill flips to `.connected`
    /// conversation-wide (and the grant separately broadcasts as a
    /// `connection_event`); an agent that needs more access re-requests under
    /// a new `requestId`.
    ///
    /// Validation: a result only counts when its XMTP-attested sender (the
    /// envelope's `senderInboxId`, persisted as the row's `senderId`) is not
    /// the request's asker — the requesting agent can't approve, deny, or
    /// cancel its own ask. This mirrors the attested-sender posture of
    /// `validateConnectionGrantRequest`; the result payload carries no sender
    /// claim of its own, so the envelope identity is the only trusted input.
    /// `staleResource` and forward-compat `unknown` statuses are not user
    /// decisions, so they never resolve. Returns nil while unresolved.
    static func resolution(results: [ResultRecord], askerInboxId: String) -> Status? {
        let decisions = results.filter { $0.senderId != askerInboxId }
        if decisions.contains(where: { $0.status == .approved }) {
            return .connected
        }
        if decisions.contains(where: { $0.status == .denied || $0.status == .cancelled }) {
            return .dismissed
        }
        return nil
    }

    /// Folds the validated resolution (see `resolution(results:askerInboxId:)`)
    /// into the pill's display state. Unresolved requests are `.pending` only
    /// when they are the conversation's latest unresolved ask; older ones are
    /// `.superseded` (visible but inert).
    static func displayStatus(
        results: [ResultRecord],
        askerInboxId: String,
        isLatestUnresolvedRequest: Bool
    ) -> Status {
        if let resolution = resolution(results: results, askerInboxId: askerInboxId) {
            return resolution
        }
        return isLatestUnresolvedRequest ? .pending : .superseded
    }

    private static func serviceName(forPreferredProvider providerId: ProviderID?, subject: CapabilitySubject) -> String {
        guard let providerId else { return subject.displayName }
        if let serviceId = providerId.cloudServiceId {
            return CloudCapabilityProvider.serviceDisplayNames[serviceId]
                ?? CloudConnectionServiceNaming.displayName(for: "", fallbackFrom: serviceId)
        }
        if let kind = ConnectionKind.fromDeviceProviderId(providerId),
           let spec = DeviceCapabilityProvider.defaultSpecs.first(where: { $0.kind == kind }) {
            return spec.displayName
        }
        return subject.displayName
    }

    private static func icon(forPreferredProvider providerId: ProviderID?, subject: CapabilitySubject) -> ConnectionEventSummary.Icon {
        guard let providerId else {
            return ConnectionMessageSummaryFormatter.icon(forSubject: subject)
        }
        return ConnectionMessageSummaryFormatter.icon(forProviderId: providerId.rawValue)
    }
}
