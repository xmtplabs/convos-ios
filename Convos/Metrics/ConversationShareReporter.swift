import ConvosCore
import ConvosMetrics
import UIKit

/// Reports `shared_conversation` for the invite share sheet.
///
/// The event has been in the metrics catalog since the funnel was defined
/// and implemented in `MetricsCoreActions`, but nothing ever called it, so
/// invite distribution - the denominator behind every join number - went
/// unmeasured. All five invite share surfaces route through the same
/// `shareSheet` modifier, so they all report through here.
enum ConversationShareReporter {
    /// Maps the activity the user picked onto the metric's dimension.
    ///
    /// A dismissed sheet reports `.cancelled` rather than going unrecorded,
    /// so abandonment stays visible: a share surface people open and back
    /// out of looks identical to one they never opened otherwise.
    static func shareTarget(
        for activityType: UIActivity.ActivityType?,
        completed: Bool
    ) -> ShareTarget {
        guard completed, let activityType else { return .cancelled }

        switch activityType {
        case .message: return .messages
        case .mail: return .mail
        case .copyToPasteboard: return .copy
        case .airDrop: return .airdrop
        default: return .other
        }
    }

    static func report(
        activityType: UIActivity.ActivityType?,
        completed: Bool,
        invite: Invite,
        conversation: Conversation?,
        coreActions: any CoreActions
    ) {
        // Nothing was shareable, so the sheet carried no invite.
        guard !invite.isEmpty else { return }

        let target: ShareTarget = shareTarget(for: activityType, completed: completed)
        let memberCount: Int = conversation?.members.count ?? 0
        let hasAssistant: Bool = conversation?.members.contains { $0.isAgent } ?? false
        let hasExpiration: Bool = invite.expiresAt != nil
        let expiresAfterUse: Bool = invite.expiresAfterUse

        Task {
            await coreActions.sharedConversation(
                memberCount: memberCount,
                hasAssistant: hasAssistant,
                shareTarget: target,
                hasExpiration: hasExpiration,
                expiresAfterUse: expiresAfterUse,
                isSuccess: completed
            )
        }
    }
}
