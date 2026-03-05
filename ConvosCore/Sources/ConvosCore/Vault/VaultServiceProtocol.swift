import Foundation

public protocol VaultServiceProtocol: Sendable {
    func unpairSelf() async throws
}
