import ConvosCore
import ConvosMessagingProtocols
import Foundation
import XMTPDTU

/// Shared state carried by `DTUMessagingClient` and its sub-surface adapters.
///
/// The DTU engine does not have a persistent "client" handle: every action
/// is dispatched against a universe and tagged with an actor alias (e.g.
/// `alice-phone`). This context collects the three pieces of information
/// every sub-adapter needs to dispatch actions on behalf of a specific
/// Convos `MessagingClient`:
///
///  - `universe` — the DTU universe to act inside. Lifetime is managed by
///    the caller (typically a test). Multiple clients can share a universe
///    when modeling multiple installations.
///  - `actor` — the installation alias (DTU-native) used as the `actor`
///    field on every dispatch. Maps 1:1 to `installationId` on the
///    abstraction surface.
///  - `inboxAlias` — the inbox alias (DTU-native) the actor belongs to.
///    Maps 1:1 to `inboxId`.
///
/// All sub-adapters hold a reference to this context rather than the
/// universe directly; that way the client can be repointed at a different
/// universe (e.g. for scenario replay) without rebuilding every adapter.
///
/// `@unchecked Sendable`: `DTUUniverse` is `@unchecked Sendable` on the
/// SDK side; the context is reference-stable and never mutated after
/// construction, so it picks up the same guarantee.
public final class DTUMessagingClientContext: @unchecked Sendable {
    public let universe: DTUUniverse
    public let actor: String
    public let inboxAlias: String

    public init(universe: DTUUniverse, actor: String, inboxAlias: String) {
        self.universe = universe
        self.actor = actor
        self.inboxAlias = inboxAlias
    }
}
