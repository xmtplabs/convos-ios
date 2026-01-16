import Foundation

public protocol InviteJoinErrorHandler: Sendable {
    func handleInviteJoinError(_ error: InviteJoinError) async
}
