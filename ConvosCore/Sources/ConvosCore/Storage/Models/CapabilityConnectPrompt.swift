import ConvosConnections
import Foundation

/// Render model for a `capability_request` row in the transcript: the centered
/// "<Agent> wants to connect" caption plus the tappable service pill.
///
/// Built at compose time. `status` is derived by joining
/// `capability_request_result` rows on `requestId` (same shape as the
/// reaction join on `sourceMessageId`) — the request row itself is never
/// edited, so the pill stays in history. Resolution is per viewer: only the
/// viewing member's own result rows flip the state that member sees, so one
/// member acting leaves every other member's pill actionable.
public struct CapabilityConnectPrompt: Hashable, Codable, Sendable {
    public enum Status: String, Hashable, Codable, Sendable {
        /// The viewing member has no validated decision of their own on the
        /// request yet and it is the conversation's latest ask unresolved for
        /// them — tapping opens the approval sheet.
        case pending
        /// The viewer's first validated result row (in message-time order)
        /// was an approval.
        case connected
        /// The viewer's first validated result row (in message-time order)
        /// was a denial or cancellation.
        case dismissed
        /// Still unresolved, but a newer unresolved request has taken over as
        /// the conversation's single actionable ask. Rendered inert; flips
        /// back to `.pending` if the newer request resolves first.
        case superseded
    }

    /// One `capability_request_result` row reduced to what status derivation
    /// needs: who sent it, what they decided, and where the row sits in
    /// message time. `sentAtNs` (the message's `dateNs`) plus `messageId` (the
    /// stable tiebreaker for identical timestamps) give
    /// `resolution(results:askerInboxId:viewerInboxId:)` its first-decision ordering; both
    /// come off the synced message row, so every device sorts identically.
    public struct ResultRecord: Hashable, Sendable {
        public let senderId: String
        public let status: CapabilityRequestResult.Status
        public let sentAtNs: Int64
        public let messageId: String

        public init(
            senderId: String,
            status: CapabilityRequestResult.Status,
            sentAtNs: Int64,
            messageId: String
        ) {
            self.senderId = senderId
            self.status = status
            self.sentAtNs = sentAtNs
            self.messageId = messageId
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
    /// for the viewer — i.e. their single actionable ask. Requests the viewer
    /// hasn't resolved that aren't it render `.superseded` instead of
    /// `.pending`, so the pill is never tappable-looking while the tap path
    /// would refuse it.
    static func make(
        request: CapabilityRequest,
        results: [ResultRecord],
        viewerInboxId: String,
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
                viewerInboxId: viewerInboxId,
                isLatestUnresolvedRequest: isLatestUnresolvedRequest
            )
        )
    }

    /// THE single definition of a "resolving" result, shared by the display
    /// derivation (pill status) and `CapabilityRequestRepository` (pending
    /// picker layout, i.e. the tap path) — both layers must always agree on
    /// whether a request is still open.
    ///
    /// Resolution is per viewer: a result row only counts toward the status
    /// the viewing member sees when its XMTP-attested sender (the envelope's
    /// `senderInboxId`, persisted as the row's `senderId`) is the viewer
    /// themselves. Each member answers the same request independently — one
    /// member approving grants their own connection (broadcast separately as
    /// a `connection_event`) and leaves every other member's pill actionable;
    /// a denial or cancellation dismisses the ask for its author alone. Among
    /// the viewer's own rows the first decision wins, in message-time order
    /// (sent timestamp, then message id as the stable tiebreaker); results
    /// are sorted here rather than trusting callers to pass them ordered, so
    /// the temporal guarantee holds in every call path.
    ///
    /// The request's asker can never resolve its own ask, even as the viewer
    /// — the requesting agent can't approve, deny, or cancel what it asked
    /// for. This mirrors the attested-sender posture of
    /// `validateConnectionGrantRequest`; the result payload carries no sender
    /// claim of its own, so the envelope identity is the only trusted input.
    /// `staleResource` and forward-compat `unknown` statuses are not user
    /// decisions, so they are skipped, never resolving. Returns nil while the
    /// viewer hasn't decided.
    static func resolution(results: [ResultRecord], askerInboxId: String, viewerInboxId: String) -> Status? {
        let ordered = results.sorted {
            ($0.sentAtNs, $0.messageId) < ($1.sentAtNs, $1.messageId)
        }
        for record in ordered where record.senderId == viewerInboxId && record.senderId != askerInboxId {
            switch record.status {
            case .approved:
                return .connected
            case .denied, .cancelled:
                return .dismissed
            case .staleResource, .unknown:
                continue
            }
        }
        return nil
    }

    /// Folds the viewer's validated resolution (see
    /// `resolution(results:askerInboxId:viewerInboxId:)`) into the pill's
    /// display state. Requests the viewer hasn't resolved are `.pending` only
    /// when they are the conversation's latest such ask; older ones are
    /// `.superseded` (visible but inert).
    static func displayStatus(
        results: [ResultRecord],
        askerInboxId: String,
        viewerInboxId: String,
        isLatestUnresolvedRequest: Bool
    ) -> Status {
        if let resolution = resolution(results: results, askerInboxId: askerInboxId, viewerInboxId: viewerInboxId) {
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
