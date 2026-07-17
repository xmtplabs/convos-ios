import Foundation

/// DEBUG-only knob that lets a developer inject a locally-minted Ed25519
/// public key as the agent-attestation fallback. Pairs with
/// `convos attestation generate <inboxId> --private-key <pem>` on the CLI:
/// the developer pastes the JWKS portion of that command's output into
/// `AGENT_DEBUG_JWKS=...` in `.env`, the build phase materializes it into
/// `Secrets.AGENT_DEBUG_JWKS`, and `AgentKeyset` accepts attestations signed
/// with the matching private key.
///
/// Input is the raw JWKS JSON (the same shape `.well-known/agents.json` serves).
/// The first key in the set is used as the fallback.
public enum DebugAgentKeysetOverride {
    public static func parse(jwksJSON: String) -> AgentKeysetEntry? {
        let trimmed = jwksJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let response = try? JSONDecoder().decode(AgentKeysetResponse.self, from: data),
              let first = response.keys.first,
              first.publicKey != nil else {
            return nil
        }
        return first
    }
}
