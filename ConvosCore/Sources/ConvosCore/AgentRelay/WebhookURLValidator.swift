import Foundation

/// Save-time validation of a webhook URL: https, host present, no userinfo,
/// and no loopback, link-local, private, IPv4-mapped, integer or hex IPv4,
/// or `.local` host. In the `.local` environment only, exact `127.0.0.1`
/// and `localhost` are accepted over http or https so the fake provider can
/// be reached from a simulator.
public struct WebhookURLValidator: Sendable {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Returns the parsed URL or throws `AgentRelayError.validation`.
    public func validate(_ string: String) throws -> URL {
        throw AgentRelayError.validation("Webhook URL validation is not implemented yet.")
    }
}
