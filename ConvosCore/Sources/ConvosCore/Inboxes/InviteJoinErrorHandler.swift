import Foundation

public protocol InviteJoinErrorHandler {
    func handleInviteJoinError(_ error: InviteJoinError) async
}
