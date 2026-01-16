import Combine
import Foundation
@preconcurrency import XMTPiOS

public protocol AuthServiceRegisteredResultType: AuthServiceResultType {
    var inbox: any AuthServiceInboxType { get }
}

public protocol AuthServiceResultType {
    var inboxes: [any AuthServiceInboxType] { get }
}

public protocol AuthServiceInboxType {
    var providerId: String { get }
    var signingKey: any XMTPiOS.SigningKey { get }
    var databaseKey: Data { get }
}

public struct AuthServiceRegisteredResult: AuthServiceRegisteredResultType {
    public let inbox: any AuthServiceInboxType
    public var inboxes: [any AuthServiceInboxType] { [inbox] }
}

public struct AuthServiceResult: AuthServiceResultType {
    public var inboxes: [any AuthServiceInboxType]
}

public struct AuthServiceInbox: AuthServiceInboxType {
    public let providerId: String
    public let signingKey: any XMTPiOS.SigningKey
    public let databaseKey: Data
}

public enum AuthServiceState {
    case unknown,
         notReady,
         registered(AuthServiceRegisteredResultType),
         authorized(AuthServiceResultType),
         unauthorized

    var isAuthenticated: Bool {
        switch self {
        case .authorized, .registered:
            return true
        default: return false
        }
    }

    var authorizedResult: AuthServiceResultType? {
        switch self {
        case .authorized(let result):
            return result
        case .registered(let result):
            return result
        default:
            return nil
        }
    }
}

public protocol AuthServiceProtocol {
    func prepare() throws

    var accountsService: (any AuthAccountsServiceProtocol)? { get }

    func signIn() async throws
    func register(displayName: String) async throws
    func signOut() async throws
}

public protocol LocalAuthServiceProtocol {
    func prepare() throws
    func register() throws -> any AuthServiceRegisteredResultType
    func deleteAccount(with providerId: String) throws
    func deleteAll() throws
    func save(inboxId: String, for providerId: String) throws
    func inboxId(for providerId: String) throws -> String
    func inbox(for inboxId: String) throws -> (any AuthServiceInboxType)?
}
