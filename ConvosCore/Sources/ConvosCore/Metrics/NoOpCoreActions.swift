import ConvosMetrics
import Foundation

public final class NoOpCoreActions: CoreActions, @unchecked Sendable {
    public init() {}

    public func startedConversation() async {}

    public func joinedConversation(
        verificationDuration: Float,
        memberCount: Int,
        hasAssistant: Bool,
        source: ConversationSource
    ) async {}

    public func conversationJoinTimedOut(
        waitDuration: Float,
        source: ConversationSource
    ) async {}

    public func invitedToConversation(memberCount: Int, hasAssistant: Bool) async {}

    public func addedAssistant(memberCount: Int) async {}

    public func assistantJoined(
        waitDuration: Float,
        surface: AssistantJoinSurface,
        memberCount: Int
    ) async {}

    public func assistantJoinTimedOut(
        waitDuration: Float,
        surface: AssistantJoinSurface
    ) async {}

    public func assistantJoinRescuedByPolling(
        streamAgeSecs: Float,
        pollTick: Int
    ) async {}

    public func sentMessage(
        sendingTime: Float,
        memberCount: Int,
        attachmentTypes: [String],
        hasText: Bool,
        hasAssistant: Bool,
        isSuccess: Bool
    ) async {}

    public func sharedConversation(
        memberCount: Int,
        hasAssistant: Bool,
        shareTarget: ShareTarget,
        hasExpiration: Bool,
        expiresAfterUse: Bool,
        isSuccess: Bool
    ) async {}

    // swiftlint:disable:next function_parameter_count
    public func builtAgent(
        buildDuration: Float,
        instructionCharCount: Int,
        instructionWordCount: Int,
        attachmentTypes: [String],
        hasVoiceMemo: Bool,
        voiceMemoDuration: Float,
        connectionTypes: [String],
        entryMode: AgentBuilderEntryMode,
        isSuccess: Bool
    ) async {}

    public func purchaseInitiated(
        productId: String,
        tier: ConvosMetrics.SubscriptionTier,
        period: ConvosMetrics.SubscriptionPeriod,
        source: ConvosMetrics.PaywallSource
    ) async {}

    public func purchaseSucceeded(
        productId: String,
        tier: ConvosMetrics.SubscriptionTier,
        period: ConvosMetrics.SubscriptionPeriod,
        source: ConvosMetrics.PaywallSource,
        durationSecs: Float
    ) async {}

    public func purchaseCancelled(productId: String, source: ConvosMetrics.PaywallSource) async {}

    public func purchaseFailed(
        productId: String,
        source: ConvosMetrics.PaywallSource,
        reason: PurchaseFailureReason
    ) async {}

    public func purchasesRestored(restoredCount: Int) async {}
}
