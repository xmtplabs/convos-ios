import Foundation

/// Runtime registry of `CapabilityProvider`s. Both `ConvosConnections` (one provider per
/// `ConnectionKind` at manager init) and the cloud-OAuth subsystem (one provider per
/// linked service) populate it.
public protocol CapabilityProviderRegistry: Sendable {
    func register(_ provider: any CapabilityProvider) async
    func unregister(id: ProviderID) async
    func providers(for subject: CapabilitySubject) async -> [any CapabilityProvider]
    func provider(id: ProviderID) async -> (any CapabilityProvider)?

    /// Observable stream of provider-registry changes. The picker / confirmation card UI
    /// subscribes so it can refresh in place when the user taps "Connect another"
    /// mid-display and completes an OAuth flow or a device permission grant.
    var providerChanges: AsyncStream<ProviderChange> { get }

    /// Notify subscribers that a registered provider's `linkedByUser` flag flipped (e.g.
    /// OAuth refreshed/expired, iOS permission granted/revoked). Owners call this; the
    /// registry doesn't poll provider state.
    func notifyLinkedStateChanged(id: ProviderID) async
}

/// Default in-memory implementation. Threadsafe via actor isolation; the
/// `providerChanges` stream multicasts through a continuation owned by the actor.
public actor InMemoryCapabilityProviderRegistry: CapabilityProviderRegistry {
    private var providersById: [ProviderID: any CapabilityProvider] = [:]
    private let continuation: AsyncStream<ProviderChange>.Continuation
    public nonisolated let providerChanges: AsyncStream<ProviderChange>

    public init() {
        let (stream, continuation) = AsyncStream<ProviderChange>.makeStream()
        self.providerChanges = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    public func register(_ provider: any CapabilityProvider) async {
        let isReplacement = providersById[provider.id] != nil
        providersById[provider.id] = provider
        continuation.yield(isReplacement ? .linkedStateChanged(provider.id) : .added(provider.id))
    }

    public func unregister(id: ProviderID) async {
        guard providersById.removeValue(forKey: id) != nil else { return }
        continuation.yield(.removed(id))
    }

    public func providers(for subject: CapabilitySubject) async -> [any CapabilityProvider] {
        providersById.values
            .filter { $0.subject == subject }
            .sorted(by: { $0.id.rawValue < $1.id.rawValue })
    }

    public func provider(id: ProviderID) async -> (any CapabilityProvider)? {
        providersById[id]
    }

    public func notifyLinkedStateChanged(id: ProviderID) async {
        guard providersById[id] != nil else { return }
        continuation.yield(.linkedStateChanged(id))
    }
}
