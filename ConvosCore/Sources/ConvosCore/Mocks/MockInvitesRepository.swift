import Combine
import Foundation

/// Mock implementation of InviteRepositoryProtocol for testing
public final class MockInviteRepository: InviteRepositoryProtocol, @unchecked Sendable {
    public var mockInvite: Invite?

    public init(invite: Invite? = .mock()) {
        self.mockInvite = invite
    }

    public var invitePublisher: AnyPublisher<Invite?, Never> {
        Just(mockInvite).eraseToAnyPublisher()
    }
}

/// Mock implementation of InvitesRepositoryProtocol for testing
public final class MockInvitesRepository: InvitesRepositoryProtocol, @unchecked Sendable {
    public var mockInvites: [Invite] = []

    public init(invites: [Invite] = []) {
        self.mockInvites = invites
    }

    public func fetchInvites(for creatorInboxId: String) async throws -> [Invite] {
        mockInvites.filter { _ in true } // Return all invites for mock
    }
}
