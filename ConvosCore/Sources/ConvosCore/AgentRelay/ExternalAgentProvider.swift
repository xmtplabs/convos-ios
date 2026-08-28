import Foundation

/// An external agent platform a user can relay turns to. The relay protocol
/// is provider-agnostic; a provider contributes a display identity, a setup
/// flow (in the app target), and a webhook auth style.
public enum ExternalAgentProvider: String, CaseIterable, Codable, Sendable {
    case town
    case tasklet

    public var displayName: String {
        switch self {
        case .town: return "Town"
        case .tasklet: return "Tasklet"
        }
    }

    /// SF Symbol used on provider rows.
    public var symbolName: String {
        switch self {
        case .town: return "building.2"
        case .tasklet: return "checklist"
        }
    }

    /// Town authenticates webhook calls with a bearer secret; Tasklet's
    /// webhook URL is itself the credential.
    public var usesBearerSecret: Bool {
        switch self {
        case .town: return true
        case .tasklet: return false
        }
    }
}
