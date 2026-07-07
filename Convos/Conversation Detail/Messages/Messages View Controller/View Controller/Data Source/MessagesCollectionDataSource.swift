import ConvosCore
import Foundation
import SwiftUI
import UIKit

protocol MessagesCollectionDataSource: UICollectionViewDataSource, MessagesLayoutDelegate {
    var sections: [MessagesCollectionSection] { get set }
    func prepare(with collectionView: UICollectionView)
    var onTapInvite: ((MessageInvite) -> Void)? { get set }
    var inviteMembershipResolver: any InviteMembershipResolving { get set }
    var agentShareResolver: any AgentShareResolving { get set }
    var onTapAgentShare: ((MessageAgentShare) -> Void)? { get set }
    var onTapAvatar: ((ConversationMember) -> Void)? { get set }
    var onTapReactions: ((AnyMessage) -> Void)? { get set }
    var onTapReadReceipts: ((MessagesGroup) -> Void)? { get set }
    var onTapThinkingIndicator: ((ThinkingSessionDescriptor) -> Void)? { get set }
    var onReaction: ((String, String) -> Void)? { get set }
    var onToggleReaction: ((String, String) -> Void)? { get set }
    var onReply: ((AnyMessage) -> Void)? { get set }
    var onOpenMessageDetail: ((AnyMessage) -> Void)? { get set }
    var expandedMessageIds: Set<String> { get set }
    var onToggleMessageExpanded: ((String) -> Void)? { get set }
    var contextMenuState: MessageContextMenuState? { get set }
    var conversationId: String { get set }
    var onPhotoDimensionsLoaded: ((String, Int, Int) -> Void)? { get set }
    var onAgentOutOfCredits: (() -> Void)? { get set }
    var creditsDepleted: Bool { get set }
    var onTapUpdateMember: ((ConversationMember) -> Void)? { get set }
    var onTapCapabilityConnect: ((CapabilityConnectPrompt) -> Void)? { get set }
    var onOpenFile: ((HydratedAttachment, AnyMessage) -> Void)? { get set }
    var onRetryMessage: ((AnyMessage) -> Void)? { get set }
    var onDeleteMessage: ((AnyMessage) -> Void)? { get set }
    var onRetryAgentJoin: (() -> Void)? { get set }
    var onCopyInviteLink: (() -> Void)? { get set }
    var onConvoCode: (() -> Void)? { get set }
    var onInviteAgent: (() -> Void)? { get set }
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)? { get set }
    var memberContactOverride: ((String) -> Contact?)? { get set }
    var isAgentJoinPending: Bool { get set }
    var headerMode: MessagesHeaderMode { get set }
    var agentBuilderTransitionNamespace: Namespace.ID? { get set }
    var htmlAttachmentTransitionNamespace: Namespace.ID? { get set }
    var hidesInviteCard: Bool { get set }
    var showsInviteScanCard: Bool { get set }
    var inviteScanConversation: Conversation? { get set }
    var inviteScanMode: InviteCodeMode { get set }
    var inviteScanInitialSegment: ScanInviteSegment { get set }
    var onScannedInviteCode: ((String) -> Void)? { get set }
    var onInviteShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)? { get set }
}
