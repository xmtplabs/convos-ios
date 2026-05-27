// Identifiable payload presented in the `.sheet(item:)` on
// ConversationsView when a `/pair/<slug>` deep link is received.

import Foundation

struct PendingPairDevice: Identifiable, Equatable {
    let id: String
    let pairingId: String
    let expiresAt: Date?
    let initiatorName: String?

    init(pairingId: String, expiresAt: Date?, initiatorName: String?) {
        self.id = pairingId
        self.pairingId = pairingId
        self.expiresAt = expiresAt
        self.initiatorName = initiatorName
    }
}
