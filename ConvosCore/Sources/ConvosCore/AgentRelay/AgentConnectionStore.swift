import Foundation

/// Per-provider connection storage split by sensitivity: secrets (the Town
/// bearer, the Tasklet webhook URL) in the Keychain, everything else in the
/// app-group defaults suite.
public protocol AgentConnectionStoreProtocol: Sendable {
    func load(provider: ExternalAgentProvider) throws -> AgentConnection?
    /// Validates the URL and the secret; throws `AgentRelayError.validation`.
    func save(_ connection: AgentConnection) throws
    func delete(provider: ExternalAgentProvider) throws
    var activeProvider: ExternalAgentProvider? { get set }
}

public final class AgentConnectionStore: AgentConnectionStoreProtocol, @unchecked Sendable {
    private let environment: AppEnvironment
    private let keychain: any KeychainServiceProtocol

    public init(environment: AppEnvironment, keychain: any KeychainServiceProtocol = KeychainService()) {
        self.environment = environment
        self.keychain = keychain
    }

    public var activeProvider: ExternalAgentProvider?

    public func load(provider: ExternalAgentProvider) throws -> AgentConnection? {
        nil
    }

    public func save(_ connection: AgentConnection) throws {
        throw AgentRelayError.notConnected
    }

    public func delete(provider: ExternalAgentProvider) throws {}
}
