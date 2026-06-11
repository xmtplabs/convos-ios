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
        /// No result row references the request yet — tapping opens the
        /// approval sheet.
        case pending
        /// An approved result row landed (from any member's device).
        case connected
        /// A denied or cancelled result row landed and no approval exists.
        case dismissed
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
    static func make(request: CapabilityRequest, results: [ResultRecord]) -> CapabilityConnectPrompt {
        let preferredProviderId = request.preferredProviders?.first
        return CapabilityConnectPrompt(
            requestId: request.requestId,
            askerInboxId: request.askerInboxId,
            serviceName: serviceName(forPreferredProvider: preferredProviderId, subject: request.subject),
            serviceId: preferredProviderId?.cloudServiceId,
            icon: icon(forPreferredProvider: preferredProviderId, subject: request.subject),
            status: displayStatus(results: results, askerInboxId: request.askerInboxId)
        )
    }

    /// Folds the result rows correlated to a request into the pill's display
    /// state. Results sent by the asker itself are ignored for approval/denial
    /// (an agent must not be able to mark its own request as connected);
    /// `staleResource` and forward-compat `unknown` statuses are not user
    /// decisions, so they leave the prompt pending.
    static func displayStatus(results: [ResultRecord], askerInboxId: String) -> Status {
        let decisions = results.filter { $0.senderId != askerInboxId }
        if decisions.contains(where: { $0.status == .approved }) {
            return .connected
        }
        if decisions.contains(where: { $0.status == .denied || $0.status == .cancelled }) {
            return .dismissed
        }
        return .pending
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
