import ConvosCore
import Foundation
import XMTPDTU

/// DTU-backed concrete factory for constructing `DTUMessagingClient` instances.
///
/// Parallels `XMTPiOSMessagingClientFactory`: same conceptual shape (a
/// factory that builds a messaging client from a per-instance
/// `MessagingClientConfig`), but the `MessagingClientFactory` protocol
/// today returns `any XMTPClientProvider` — a legacy XMTPiOS-specific
/// type — which means the DTU factory can't conform to the existing
/// protocol without depending on XMTPiOS.
///
/// Rather than pulling XMTPiOS in (which would defeat the whole point of
/// the separate `ConvosCoreDTU` package), this factory exposes its own
/// narrower entry points: `createClient(...)` and `buildClient(...)`,
/// both returning `DTUMessagingClient` directly. When Stage 6 retires
/// `XMTPClientProvider` from the `MessagingClientFactory` return types,
/// `DTUMessagingClientFactory` can conform to the protocol cleanly.
///
/// The factory stores a reference to a `DTUUniverse`. Callers own
/// universe creation + teardown; the factory is a thin handle registry
/// on top of it.
public struct DTUMessagingClientFactory: Sendable {
    public let universe: DTUUniverse

    public init(universe: DTUUniverse) {
        self.universe = universe
    }

    /// Build a brand-new DTU-backed messaging client.
    ///
    /// The signer's identity `identifier` is used as the DTU alias for
    /// the user / inbox / installation triple. If those aliases already
    /// exist in the universe, the call is idempotent (DTU's
    /// "already exists" errors are swallowed).
    ///
    /// `config` is currently unused — DTU's engine doesn't consult the
    /// `dbEncryptionKey` / `dbDirectory` / `apiEnv` knobs that the
    /// XMTPiOS factory does. Kept in the signature to mirror the
    /// reference factory's shape so a Stage 6+ refactor can swap in
    /// either backend from the same call site.
    public func createClient(
        signer: any MessagingSigner,
        config: MessagingClientConfig
    ) async throws -> DTUMessagingClient {
        let alias = signer.identity.identifier
        try await bootstrapActor(
            universe: universe,
            userAlias: alias,
            inboxAlias: alias,
            installationAlias: alias
        )
        return DTUMessagingClient(
            universe: universe,
            inboxAlias: alias,
            installationAlias: alias
        )
    }

    /// Rehydrate an existing client from the universe.
    ///
    /// DTU's universe is the single source of truth; there's no local
    /// DB to rehydrate from, so "build" is structurally equivalent to
    /// "attach". Kept separate to parallel the XMTPiOS factory shape.
    public func buildClient(
        inboxId: String,
        identity: MessagingIdentity,
        config: MessagingClientConfig
    ) async throws -> DTUMessagingClient {
        let alias = inboxId.isEmpty ? identity.identifier : inboxId
        return DTUMessagingClient(
            universe: universe,
            inboxAlias: alias,
            installationAlias: alias
        )
    }

    /// Variant that lets the caller specify distinct inbox + installation
    /// aliases. Mirrors the DTU test harness convention where a user has
    /// `alice-main` as the inbox and `alice-phone` / `alice-laptop` as
    /// installation aliases.
    public func attachClient(
        userAlias: String,
        inboxAlias: String,
        installationAlias: String,
        bootstrap: Bool = true
    ) async throws -> DTUMessagingClient {
        if bootstrap {
            try await bootstrapActor(
                universe: universe,
                userAlias: userAlias,
                inboxAlias: inboxAlias,
                installationAlias: installationAlias
            )
        }
        return DTUMessagingClient(
            universe: universe,
            inboxAlias: inboxAlias,
            installationAlias: installationAlias
        )
    }
}
