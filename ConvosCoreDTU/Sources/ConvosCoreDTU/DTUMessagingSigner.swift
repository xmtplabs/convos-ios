import ConvosCore
import ConvosMessagingProtocols
import Foundation

/// Passthrough adapter between the abstraction's `MessagingSigner` and
/// the DTU engine.
///
/// DTU's engine is a universe simulator — it does not verify real
/// signatures, so there is no native "signing key" concept to adapt
/// into. The signer is still carried across the adapter boundary so
/// that flows like `MessagingClient.create(signer:config:)` can be
/// invoked uniformly; we just don't use it to actually sign bytes.
///
/// This file is intentionally tiny. It exists as a named touchpoint so
/// future DTU engine work (e.g. a fault-injection flow that exercises
/// the signer surface) has an obvious home. Today the only way a signer
/// flows into the adapter is through `DTUMessagingClient.create`, which
/// reads `signer.identity.identifier` to derive the actor alias.
public struct DTUMessagingSignerBridge: Sendable {
    public let signer: any MessagingSigner

    public init(_ signer: any MessagingSigner) {
        self.signer = signer
    }

    /// Derive a DTU actor alias from the signer's identity. Convention:
    /// DTU tests use short lowercased aliases like `alice-phone`; the
    /// bridge does a best-effort projection from the identity's opaque
    /// identifier. Callers that need a specific alias should construct
    /// a `DTUMessagingClient` directly via `attach(...)` instead of
    /// going through the `create(signer:config:)` path.
    public var derivedActorAlias: String {
        signer.identity.identifier
    }
}
