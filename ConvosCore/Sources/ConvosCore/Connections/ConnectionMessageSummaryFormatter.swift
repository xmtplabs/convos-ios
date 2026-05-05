import ConvosConnections
import Foundation

public enum ConnectionMessageSummaryFormatter {
    public static func eventSummary(_ event: ConnectionEvent) -> ConnectionEventSummary {
        switch event.action {
        case .granted:
            return .init(
                text: grantedText(forProviderId: event.providerId, capability: event.capability),
                outcome: .success,
                icon: icon(forProviderId: event.providerId),
                actor: .verifiedAssistant
            )
        case .revoked:
            return .init(
                text: revokedText(forProviderId: event.providerId, capability: event.capability),
                outcome: .success,
                icon: icon(forProviderId: event.providerId),
                actor: nil
            )
        }
    }

    public static func invocationSummary(_ invocation: ConnectionInvocation) -> ConnectionEventSummary {
        let phrase: String
        switch (invocation.kind, invocation.action.name) {
        case (.health, "fetch_summary_last_24h"):
            phrase = "read last 24 hours of health data"
        case (.health, "fetch_samples"):
            phrase = "requested health samples"
        case (.health, "log_water"):
            phrase = "logged water intake"
        case (.health, "log_caffeine"):
            phrase = "logged caffeine intake"
        case (.health, "log_mindful_minutes"):
            phrase = "logged mindful minutes"
        default:
            phrase = "used \(invocation.kind.displayName.lowercased()) \(humanize(invocation.action.name))"
        }
        return .init(
            text: phrase,
            outcome: .pending,
            icon: icon(for: invocation.kind),
            actor: .messageSender
        )
    }

    /// Formats a `ConnectionPayload` (a device-to-agent background update) for
    /// display in the messages list. Actor is `.messageSender` so the renderer
    /// prepends the underlying message's sender.
    public static func payloadSummary(_ payload: ConnectionPayload) -> ConnectionEventSummary {
        let label = activityLabel(for: payload.source)
        return .init(
            text: "added \(label) activity",
            outcome: .success,
            icon: icon(for: payload.source),
            actor: .messageSender
        )
    }

    private static func activityLabel(for kind: ConnectionKind) -> String {
        switch kind {
        case .health:
            return "health"
        case .calendar:
            return "calendar"
        case .contacts:
            return "contacts"
        case .photos:
            return "photo"
        case .music:
            return "music"
        case .homeKit:
            return "home"
        case .location:
            return "location"
        case .motion:
            return "motion"
        case .screenTime:
            return "screen time"
        }
    }

    public static func resultSummary(_ result: ConnectionInvocationResult) -> ConnectionEventSummary {
        switch result.status {
        case .success:
            let phrase: String
            switch (result.kind, result.actionName) {
            case (.health, "fetch_summary_last_24h"):
                phrase = "read last 24 hours of health data"
            case (.health, "fetch_samples"):
                phrase = "read health samples"
            case (.health, "log_water"):
                phrase = "logged water intake"
            case (.health, "log_caffeine"):
                phrase = "logged caffeine intake"
            case (.health, "log_mindful_minutes"):
                phrase = "logged mindful minutes"
            default:
                phrase = "completed \(result.kind.displayName.lowercased()) \(humanize(result.actionName))"
            }
            return .init(text: phrase, outcome: .success, icon: icon(for: result.kind), actor: .messageSender)
        case .capabilityNotEnabled, .capabilityRevoked, .authorizationDenied, .requiresConfirmation, .unknownAction, .executionFailed:
            return .init(
                text: failedText(for: result),
                outcome: .failure,
                icon: .error,
                actor: .messageSender
            )
        }
    }

    private static func grantedText(forProviderId providerId: String, capability: ConnectionCapability?) -> String {
        let id = ProviderID(rawValue: providerId)
        if let kind = ConnectionKind.fromDeviceProviderId(id) {
            return grantedText(forDeviceKind: kind, capability: capability)
        }
        if let serviceId = id.cloudServiceId,
           let subject = CloudCapabilityProvider.serviceSubjectMap[serviceId] {
            return grantedText(forSubject: subject, capability: capability)
        }
        return "has access to connection data"
    }

    private static func revokedText(forProviderId providerId: String, capability: ConnectionCapability?) -> String {
        let id = ProviderID(rawValue: providerId)
        if let kind = ConnectionKind.fromDeviceProviderId(id) {
            return revokedText(forDeviceKind: kind, capability: capability)
        }
        if let serviceId = id.cloudServiceId,
           let subject = CloudCapabilityProvider.serviceSubjectMap[serviceId] {
            return revokedText(forSubject: subject, capability: capability)
        }
        return "Connection removed"
    }

    private static func grantedText(forDeviceKind kind: ConnectionKind, capability: ConnectionCapability?) -> String {
        guard let capability else { return defaultGrantedText(forDeviceKind: kind) }
        return "can \(verb(for: capability)) \(noun(forDeviceKind: kind))"
    }

    private static func revokedText(forDeviceKind kind: ConnectionKind, capability: ConnectionCapability?) -> String {
        guard let capability else { return defaultRevokedText(forDeviceKind: kind) }
        return "\(noun(forDeviceKind: kind, capitalized: true)) \(capability.displayName.lowercased()) access removed"
    }

    private static func grantedText(forSubject subject: CapabilitySubject, capability: ConnectionCapability?) -> String {
        guard let capability else { return defaultGrantedText(forSubject: subject) }
        return "can \(verb(for: capability)) \(noun(forSubject: subject))"
    }

    private static func revokedText(forSubject subject: CapabilitySubject, capability: ConnectionCapability?) -> String {
        guard let capability else { return defaultRevokedText(forSubject: subject) }
        return "\(noun(forSubject: subject, capitalized: true)) \(capability.displayName.lowercased()) access removed"
    }

    private static func verb(for capability: ConnectionCapability) -> String {
        switch capability {
        case .read:
            return "read"
        case .writeCreate:
            return "create"
        case .writeUpdate:
            return "edit"
        case .writeDelete:
            return "delete"
        }
    }

    private static func noun(forDeviceKind kind: ConnectionKind, capitalized: Bool = false) -> String {
        let value: String
        switch kind {
        case .health:
            value = "health data"
        case .calendar:
            value = "calendar events"
        case .contacts:
            value = "contacts"
        case .photos:
            value = "photos"
        case .music:
            value = "music"
        case .homeKit:
            value = "home devices"
        case .location:
            value = "location data"
        case .screenTime:
            value = "Screen Time data"
        case .motion:
            value = "motion data"
        }
        return capitalized ? value.prefix(1).uppercased() + value.dropFirst() : value
    }

    private static func noun(forSubject subject: CapabilitySubject, capitalized: Bool = false) -> String {
        let value: String
        switch subject {
        case .calendar:
            value = "calendar events"
        case .contacts:
            value = "contacts"
        case .tasks:
            value = "tasks"
        case .mail:
            value = "emails"
        case .photos:
            value = "photos"
        case .fitness:
            value = "fitness data"
        case .music:
            value = "music"
        case .location:
            value = "location data"
        case .home:
            value = "home devices"
        case .screenTime:
            value = "Screen Time data"
        }
        return capitalized ? value.prefix(1).uppercased() + value.dropFirst() : value
    }

    private static func defaultGrantedText(forDeviceKind kind: ConnectionKind) -> String {
        switch kind {
        case .health:
            return "has access to health data"
        case .calendar:
            return "has access to calendar data"
        case .contacts:
            return "has access to contacts data"
        case .photos:
            return "has access to photos"
        case .music:
            return "has access to music data"
        case .homeKit:
            return "has access to home data"
        case .location:
            return "has access to location data"
        case .screenTime:
            return "has access to Screen Time data"
        case .motion:
            return "has access to motion data"
        }
    }

    private static func defaultRevokedText(forDeviceKind kind: ConnectionKind) -> String {
        switch kind {
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
        }
    }

    private static func defaultGrantedText(forSubject subject: CapabilitySubject) -> String {
        switch subject {
        case .calendar:
            return "has access to calendar data"
        case .contacts:
            return "has access to contacts data"
        case .tasks:
            return "has access to tasks"
        case .mail:
            return "has access to mail"
        case .photos:
            return "has access to photos"
        case .fitness:
            return "has access to fitness data"
        case .music:
            return "has access to music data"
        case .location:
            return "has access to location data"
        case .home:
            return "has access to home data"
        case .screenTime:
            return "has access to Screen Time data"
        }
    }

    private static func defaultRevokedText(forSubject subject: CapabilitySubject) -> String {
        switch subject {
        case .calendar:
            return "Calendar connection removed"
        case .contacts:
            return "Contacts connection removed"
        case .tasks:
            return "Tasks connection removed"
        case .mail:
            return "Mail connection removed"
        case .photos:
            return "Photos connection removed"
        case .fitness:
            return "Fitness connection removed"
        case .music:
            return "Music connection removed"
        case .location:
            return "Location connection removed"
        case .home:
            return "Home connection removed"
        case .screenTime:
            return "Screen Time connection removed"
        }
    }

    private static func failedText(for result: ConnectionInvocationResult) -> String {
        switch (result.kind, result.actionName) {
        case (.health, "fetch_summary_last_24h"):
            return "failed to read last 24 hours of health data"
        case (.health, "fetch_samples"):
            return "failed to read health samples"
        default:
            return "failed to use \(result.kind.displayName.lowercased()) \(humanize(result.actionName))"
        }
    }

    private static func icon(forProviderId providerId: String) -> ConnectionEventSummary.Icon {
        let id = ProviderID(rawValue: providerId)
        if let kind = ConnectionKind.fromDeviceProviderId(id) {
            return icon(for: kind)
        }
        if let serviceId = id.cloudServiceId,
           let subject = CloudCapabilityProvider.serviceSubjectMap[serviceId] {
            return icon(for: subject)
        }
        return .generic
    }

    private static func icon(for subject: CapabilitySubject) -> ConnectionEventSummary.Icon {
        switch subject {
        case .calendar:
            return .calendar
        case .contacts:
            return .contacts
        case .photos:
            return .photos
        case .music:
            return .music
        case .home:
            return .home
        case .fitness:
            return .health
        case .mail, .tasks, .location, .screenTime:
            return .generic
        }
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
