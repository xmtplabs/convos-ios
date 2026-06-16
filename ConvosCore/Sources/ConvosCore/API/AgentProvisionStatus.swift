import Foundation

/// Lifecycle of a provisioning agent instance as reported by the backend's
/// `GET /v2/agents/join/:instanceId` poll. Distinct from `AgentJoinStatus`,
/// which is the in-conversation join row rendered in the message list — the
/// two have different value sets and live on different code paths.
///
/// Modeled as a closed `switch` with an `.unknown` escape hatch rather than a
/// raw `String`: the poll loop switches over this so that a terminal status
/// this client build doesn't yet model surfaces as a handled `.unknown` case
/// (logged, deadline-bounded) instead of being silently treated as
/// "keep waiting". Decoding stays lenient — an unmodeled status maps to
/// `.unknown` rather than throwing — so a backend that adds a new status can't
/// break the poll outright.
public enum AgentProvisionStatus: Equatable, Sendable {
    /// Registering the agent's XMTP identity / publishing key packages. In
    /// direct-add this persists until the caller's `addMembers` lands; the
    /// agent's `inboxId` becomes available partway through (see below).
    case starting
    /// The agent has joined the group (slug flow).
    case joined
    /// The agent's container has booted — strictly after `joined`; treated as
    /// joined wherever a join is awaited.
    case ready
    /// Slug flow only: provisioned, waiting on an online accepter. Not emitted
    /// for direct-add.
    case pendingAcceptance
    /// Pool exhausted — no agent instance could be allocated. Terminal.
    /// Normally surfaced as a 503 on the provision POST; modeled here too so
    /// the poll reports "no agents available" rather than spinning to a
    /// generic timeout if the backend ever reports it mid-poll.
    case noAgentsAvailable
    /// Terminal failure; pair with `joinFailureReason` for the cause.
    case failed
    /// A status string this build does not model. Never silently swallowed —
    /// the poll loop logs it and lets its own deadline bound the wait.
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "starting": self = .starting
        case "joined": self = .joined
        case "ready": self = .ready
        case "pending_acceptance": self = .pendingAcceptance
        case "no_agents_available": self = .noAgentsAvailable
        case "failed": self = .failed
        default: self = .unknown(wire)
        }
    }
}
