import ConvosConnections
import Foundation

/// Inputs the host app passes when constructing `ConvosClient` to opt in to specific
/// `ConvosConnections` device kinds (HealthKit, EventKit, CoreLocation, etc.).
///
/// The host is the only place that knows which per-kind package products it has linked.
/// ConvosCore consumes these as opaque protocols and never references concrete
/// per-kind types, which is what keeps unwanted Apple frameworks out of the binary
/// when the host doesn't link them.
///
/// Use `.none` to opt out of every device kind (v1: cloud-only / Google Calendar
/// via Composio).
public struct DeviceConnectionsBundle: Sendable {
    /// `DataSource` instances the host wants surfaced to the picker and the
    /// invocation runtime. One per supported `ConnectionKind`.
    public let dataSources: [any DataSource]

    /// `DataSink` instances the host wants to handle inbound invocations.
    public let dataSinks: [any DataSink]

    /// Concrete HealthKit-backed implementations of the four protocols
    /// `ConnectionInvocationRuntime` needs to wire the health background-delivery
    /// path. `nil` when the host doesn't link Health — the runtime then skips
    /// constructing `HealthInvocationRouter` and the health background subscribe/
    /// unsubscribe path is unavailable.
    public let health: HealthRuntimeImpls?

    public init(
        dataSources: [any DataSource] = [],
        dataSinks: [any DataSink] = [],
        health: HealthRuntimeImpls? = nil
    ) {
        self.dataSources = dataSources
        self.dataSinks = dataSinks
        self.health = health
    }

    /// Empty bundle. The host opts out of every device kind.
    public static let none: DeviceConnectionsBundle = .init()
}

/// HealthKit-backed implementations of the four `ConvosConnections` protocols
/// `ConnectionInvocationRuntime` needs to bootstrap background delivery.
/// `GRDBHealthBackgroundSubscriptionStore` (a GRDB-only Core type) is constructed
/// by `SyncingManager` and not part of this bundle; only the HKHealthStore-backed
/// types are gated here because they're the ones that pull HealthKit into the
/// binary.
public struct HealthRuntimeImpls: Sendable {
    public let backgroundDeliveryGateway: any HealthBackgroundDeliveryGateway
    public let backfillReader: any HealthBackfillReader
    public let deltaReader: any HealthDeltaReader
    public let observerRegistrar: any HealthBackgroundObserverRegistrar

    public init(
        backgroundDeliveryGateway: any HealthBackgroundDeliveryGateway,
        backfillReader: any HealthBackfillReader,
        deltaReader: any HealthDeltaReader,
        observerRegistrar: any HealthBackgroundObserverRegistrar
    ) {
        self.backgroundDeliveryGateway = backgroundDeliveryGateway
        self.backfillReader = backfillReader
        self.deltaReader = deltaReader
        self.observerRegistrar = observerRegistrar
    }
}
