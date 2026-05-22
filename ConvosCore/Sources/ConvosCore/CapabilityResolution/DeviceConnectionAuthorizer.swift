import ConvosConnections
import Foundation

/// Routes per-`ConnectionKind` authorization queries into the matching
/// `ConvosConnections` data-source. Lets the picker's Connect path drive an iOS
/// permission prompt without ConvosCore having to know about HealthKit / EventKit /
/// etc. directly.
public protocol DeviceConnectionAuthorizer: Sendable {
    /// Current cached/known status. Cheap; doesn't prompt the user.
    func currentAuthorization(for kind: ConnectionKind) async -> ConnectionAuthorizationStatus

    /// Prompt for authorization if `notDetermined`; otherwise return current status.
    /// Throws if the underlying system call fails.
    @discardableResult
    func requestAuthorization(for kind: ConnectionKind) async throws -> ConnectionAuthorizationStatus
}

public struct DefaultDeviceConnectionAuthorizer: DeviceConnectionAuthorizer {
    private let dataSourcesByKind: [ConnectionKind: any DataSource]

    /// `dataSources` is the same array the host passes via
    /// `PlatformProviders.deviceConnections.dataSources` — one `DataSource` per
    /// `ConnectionKind` the host has linked. Unsupported kinds (missing from the
    /// array) resolve to `UnsupportedKindDataSource` and report `.unavailable`,
    /// which the UI already treats as "hide / disabled".
    public init(dataSources: [any DataSource]) {
        var byKind: [ConnectionKind: any DataSource] = [:]
        for source in dataSources {
            byKind[source.kind] = source
        }
        self.dataSourcesByKind = byKind
    }

    public func currentAuthorization(for kind: ConnectionKind) async -> ConnectionAuthorizationStatus {
        await dataSource(for: kind).authorizationStatus()
    }

    public func requestAuthorization(for kind: ConnectionKind) async throws -> ConnectionAuthorizationStatus {
        try await dataSource(for: kind).requestAuthorization()
    }

    private func dataSource(for kind: ConnectionKind) -> any DataSource {
        dataSourcesByKind[kind] ?? UnsupportedKindDataSource(kind: kind)
    }
}

private struct UnsupportedKindDataSource: DataSource, Sendable {
    let kind: ConnectionKind

    func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    func stop() async {}
}
