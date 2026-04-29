import ConvosConnections
import Foundation

public enum ConnectionMessageSummaryFormatter {
    public static func eventSummary(_ event: ConnectionEvent) -> ConnectionEventSummary {
        switch event.action {
        case .granted:
            return .init(
                text: grantedText(forProviderId: event.providerId),
                outcome: .success,
                icon: icon(forProviderId: event.providerId)
            )
        case .revoked:
            return .init(
                text: revokedText(forProviderId: event.providerId),
                outcome: .success,
                icon: icon(forProviderId: event.providerId)
            )
        }
    }

    public static func invocationSummary(_ invocation: ConnectionInvocation, senderName: String? = nil) -> ConnectionEventSummary {
        let actor = senderName ?? "Assistant"
        switch (invocation.kind, invocation.action.name) {
        case (.health, "fetch_summary_last_24h"):
            return .init(text: "\(actor) read last 24 hours of health data", outcome: .pending, icon: .health)
        case (.health, "fetch_samples"):
            return .init(text: "\(actor) requested health samples", outcome: .pending, icon: .health)
        case (.health, "log_water"):
            return .init(text: "\(actor) logged water intake", outcome: .pending, icon: .health)
        case (.health, "log_caffeine"):
            return .init(text: "\(actor) logged caffeine intake", outcome: .pending, icon: .health)
        case (.health, "log_mindful_minutes"):
            return .init(text: "\(actor) logged mindful minutes", outcome: .pending, icon: .health)
        default:
            return .init(
                text: "\(actor) used \(invocation.kind.displayName.lowercased()) \(humanize(invocation.action.name))",
                outcome: .pending,
                icon: icon(for: invocation.kind)
            )
        }
    }

    public static func resultSummary(_ result: ConnectionInvocationResult, senderName: String? = nil) -> ConnectionEventSummary {
        let actor = senderName ?? "Assistant"
        switch result.status {
        case .success:
            switch (result.kind, result.actionName) {
            case (.health, "fetch_summary_last_24h"):
                return .init(text: "\(actor) read last 24 hours of health data", outcome: .success, icon: .health)
            case (.health, "fetch_samples"):
                return .init(text: "\(actor) read health samples", outcome: .success, icon: .health)
            case (.health, "log_water"):
                return .init(text: "\(actor) logged water intake", outcome: .success, icon: .health)
            case (.health, "log_caffeine"):
                return .init(text: "\(actor) logged caffeine intake", outcome: .success, icon: .health)
            case (.health, "log_mindful_minutes"):
                return .init(text: "\(actor) logged mindful minutes", outcome: .success, icon: .health)
            default:
                return .init(
                    text: "\(actor) completed \(result.kind.displayName.lowercased()) \(humanize(result.actionName))",
                    outcome: .success,
                    icon: icon(for: result.kind)
                )
            }
        case .capabilityNotEnabled, .capabilityRevoked, .authorizationDenied, .requiresConfirmation, .unknownAction, .executionFailed:
            return .init(
                text: failedText(for: result, actor: actor),
                outcome: .failure,
                icon: .error
            )
        }
    }

    private static func grantedText(forProviderId providerId: String) -> String {
        switch ConnectionKind.fromDeviceProviderId(ProviderID(rawValue: providerId)) {
        case .health:
            return "Assistant has access to health data"
        case .calendar:
            return "Assistant has access to calendar data"
        case .contacts:
            return "Assistant has access to contacts data"
        case .photos:
            return "Assistant has access to photos"
        case .music:
            return "Assistant has access to music data"
        case .homeKit:
            return "Assistant has access to home data"
        case .location:
            return "Assistant has access to location data"
        case .screenTime:
            return "Assistant has access to Screen Time data"
        case .motion:
            return "Assistant has access to motion data"
        case .none:
            return "Assistant has access to connection data"
        }
    }

    private static func revokedText(forProviderId providerId: String) -> String {
        switch ConnectionKind.fromDeviceProviderId(ProviderID(rawValue: providerId)) {
        case .health:
            return "Health data connection removed"
        case .calendar:
            return "Calendar data connection removed"
        case .contacts:
            return "Contacts data connection removed"
        case .photos:
            return "Photos connection removed"
        case .music:
            return "Music data connection removed"
        case .homeKit:
            return "Home data connection removed"
        case .location:
            return "Location data connection removed"
        case .screenTime:
            return "Screen Time connection removed"
        case .motion:
            return "Motion data connection removed"
        case .none:
            return "Connection removed"
        }
    }

    private static func failedText(for result: ConnectionInvocationResult, actor: String) -> String {
        switch (result.kind, result.actionName) {
        case (.health, "fetch_summary_last_24h"):
            return "\(actor) failed to read last 24 hours of health data"
        case (.health, "fetch_samples"):
            return "\(actor) failed to read health samples"
        default:
            return "\(actor) failed to use \(result.kind.displayName.lowercased()) \(humanize(result.actionName))"
        }
    }

    private static func icon(forProviderId providerId: String) -> ConnectionEventSummary.Icon {
        guard let kind = ConnectionKind.fromDeviceProviderId(ProviderID(rawValue: providerId)) else {
            return .generic
        }
        return icon(for: kind)
    }

    private static func icon(for kind: ConnectionKind) -> ConnectionEventSummary.Icon {
        switch kind {
        case .health:
            return .health
        case .calendar:
            return .calendar
        case .contacts:
            return .contacts
        case .photos:
            return .photos
        case .music:
            return .music
        case .homeKit:
            return .home
        case .location, .motion, .screenTime:
            return .generic
        }
    }

    private static func humanize(_ actionName: String) -> String {
        actionName
            .split(separator: "_")
            .joined(separator: " ")
    }
}
