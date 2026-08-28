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
    private let defaults: UserDefaults

    public init(environment: AppEnvironment, keychain: any KeychainServiceProtocol = KeychainService()) {
        self.environment = environment
        self.keychain = keychain
        defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
    }

    public var activeProvider: ExternalAgentProvider? {
        get {
            guard let rawValue = defaults.string(forKey: Constant.activeProviderKey) else { return nil }
            return ExternalAgentProvider(rawValue: rawValue)
        }
        set {
            defaults.set(newValue?.rawValue, forKey: Constant.activeProviderKey)
        }
    }

    public func load(provider: ExternalAgentProvider) throws -> AgentConnection? {
        guard defaults.bool(forKey: connectedKey(for: provider)) else { return nil }

        switch provider {
        case .town:
            guard let urlString = defaults.string(forKey: Constant.townWebhookURLKey),
                  let url = URL(string: urlString),
                  let secret = try keychain.retrieveString(account: Constant.townSecretAccount),
                  !secret.isEmpty else {
                return nil
            }
            return AgentConnection(provider: .town, webhookURL: url, auth: .bearer(secret: secret))
        case .tasklet:
            guard let urlString = try keychain.retrieveString(account: Constant.taskletWebhookURLAccount),
                  let url = URL(string: urlString) else {
                return nil
            }
            return AgentConnection(provider: .tasklet, webhookURL: url, auth: .capabilityURL)
        }
    }

    public func save(_ connection: AgentConnection) throws {
        let validatedURL = try WebhookURLValidator(environment: environment).validate(connection.webhookURL.absoluteString)

        switch (connection.provider, connection.auth) {
        case let (.town, .bearer(secret)):
            guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentRelayError.validation("Town webhook secret cannot be empty.")
            }
            try keychain.saveString(secret, account: Constant.townSecretAccount)
            defaults.set(validatedURL.absoluteString, forKey: Constant.townWebhookURLKey)
        case (.tasklet, .capabilityURL):
            try keychain.saveString(validatedURL.absoluteString, account: Constant.taskletWebhookURLAccount)
        case (.town, .capabilityURL):
            throw AgentRelayError.validation("Town requires a webhook bearer secret.")
        case (.tasklet, .bearer):
            throw AgentRelayError.validation("Tasklet uses its webhook URL as the connection secret.")
        }

        defaults.set(true, forKey: connectedKey(for: connection.provider))
        activeProvider = connection.provider
    }

    public func delete(provider: ExternalAgentProvider) throws {
        var keychainError: Error?
        switch provider {
        case .town:
            do {
                try keychain.delete(account: Constant.townSecretAccount)
            } catch {
                keychainError = error
            }
            defaults.removeObject(forKey: Constant.townWebhookURLKey)
        case .tasklet:
            do {
                try keychain.delete(account: Constant.taskletWebhookURLAccount)
            } catch {
                keychainError = error
            }
        }
        defaults.removeObject(forKey: connectedKey(for: provider))
        if activeProvider == provider {
            activeProvider = nil
        }
        guard let keychainError else { return }
        throw keychainError
    }

    private func connectedKey(for provider: ExternalAgentProvider) -> String {
        switch provider {
        case .town: Constant.townConnectedKey
        case .tasklet: Constant.taskletConnectedKey
        }
    }

    private enum Constant {
        static let activeProviderKey: String = "agentRelay.activeProvider"
        static let taskletConnectedKey: String = "agentRelay.tasklet.connected"
        static let taskletWebhookURLAccount: String = "agentRelay.tasklet.webhookURL"
        static let townConnectedKey: String = "agentRelay.town.connected"
        static let townSecretAccount: String = "agentRelay.town.secret"
        static let townWebhookURLKey: String = "agentRelay.town.webhookURL"
    }
}
