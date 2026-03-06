import Foundation

extension DBInbox {
    func toDomain() -> Inbox {
        Inbox(
            inboxId: inboxId,
            clientId: clientId,
            createdAt: createdAt,
            isVault: isVault
        )
    }
}
