import ConvosConnections
import Foundation

/// Allowlist of connections currently surfaced to users.
///
/// We are rolling support out one provider at a time. A `ConnectionKind` or
/// cloud service id only appears in the connections UI if it is listed here.
/// To enable a new provider, add its case/id to the matching set.
enum SupportedConnections {
    static let supportedDeviceKinds: Set<ConnectionKind> = [
        .health,
    ]

    static let supportedCloudServiceIds: Set<String> = [
        "google_calendar",
    ]

    static func isSupported(_ kind: ConnectionKind) -> Bool {
        supportedDeviceKinds.contains(kind)
    }

    static func isSupported(cloudServiceId: String) -> Bool {
        supportedCloudServiceIds.contains(cloudServiceId)
    }
}
