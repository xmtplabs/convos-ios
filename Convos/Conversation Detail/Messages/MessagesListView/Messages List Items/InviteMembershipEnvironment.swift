import ConvosCore
import SwiftUI

/// Environment delivery for the in-chat invite card's membership resolver.
/// Injected once at the cell (like `agentShareResolver`) so the card can show
/// the linked conversation's member count when the current user has already
/// joined, without threading the resolver through the deep messages hierarchy.

private struct InviteMembershipResolverKey: EnvironmentKey {
    static let defaultValue: any InviteMembershipResolving = NoopInviteMembershipResolver()
}

extension EnvironmentValues {
    var inviteMembershipResolver: any InviteMembershipResolving {
        get { self[InviteMembershipResolverKey.self] }
        set { self[InviteMembershipResolverKey.self] = newValue }
    }
}
