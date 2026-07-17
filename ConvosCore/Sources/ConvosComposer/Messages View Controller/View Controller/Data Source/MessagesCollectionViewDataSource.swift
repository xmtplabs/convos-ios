#if canImport(UIKit)
import ConvosCore
import ConvosLogging
import Foundation
import SwiftUI
import UIKit

@MainActor
final class MessagesCollectionViewDataSource: NSObject {
    var sections: [MessagesCollectionSection] = [] {
        didSet {
            layoutDelegate = DefaultMessagesLayoutDelegate(sections: sections,
                                                           oldSections: layoutDelegate.sections)
        }
    }

    var conversationId: String = ""
    var onTapAvatar: ((ConversationMember) -> Void)?
    var onTapInvite: ((MessageInvite) -> Void)?
    var inviteMembershipResolver: any InviteMembershipResolving = NoopInviteMembershipResolver()
    var agentShareResolver: any AgentShareResolving = MockAgentShareResolver()
    var onTapAgentShare: ((MessageAgentShare) -> Void)?
    var onTapReactions: ((AnyMessage) -> Void)?
    var onTapReadReceipts: ((MessagesGroup) -> Void)?
    var onTapThinkingIndicator: ((ThinkingSessionDescriptor) -> Void)?
    var onReaction: ((String, String) -> Void)?
    var onToggleReaction: ((String, String) -> Void)?
    var onReply: ((AnyMessage) -> Void)?
    var onOpenMessageDetail: ((AnyMessage) -> Void)?
    var expandedMessageIds: Set<String> = []
    var onToggleMessageExpanded: ((String) -> Void)?
    var contextMenuState: MessageContextMenuState?
    var onPhotoDimensionsLoaded: ((String, Int, Int) -> Void)?
    var onAgentOutOfCredits: (() -> Void)?
    var creditsDepleted: Bool = false
    var onTapUpdateMember: ((ConversationMember) -> Void)?
    var onTapCapabilityConnect: ((CapabilityConnectPrompt) -> Void)?
    var onOpenFile: ((HydratedAttachment, AnyMessage) -> Void)?
    var onRetryMessage: ((AnyMessage) -> Void)?
    var onDeleteMessage: ((AnyMessage) -> Void)?
    var onRetryAgentJoin: (() -> Void)?
    var onCopyInviteLink: (() -> Void)?
    var onConvoCode: (() -> Void)?
    var onInviteAgent: (() -> Void)?
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?
    var memberContactOverride: ((String) -> Contact?)?
    var isAgentJoinPending: Bool = false
    var headerMode: MessagesHeaderMode = .standard
    var agentBuilderTransitionNamespace: Namespace.ID?
    var htmlAttachmentTransitionNamespace: Namespace.ID?
    var hidesInviteCard: Bool = false
    var agentBuilderSummaryProvider: ((AgentBuilderCardContent) -> AnyView)?
    var currentUserProfileImage: (() -> UIImage?)?
    var backwardsSecrecyInfoSheet: (() -> AnyView)?
    var showsInviteScanCard: Bool = false
    var inviteScanConversation: Conversation?
    var inviteScanMode: InviteCodeMode = .inConvo
    var inviteScanInitialSegment: ScanInviteSegment = .invite
    var onScannedInviteCode: ((String) -> Void)?
    var onInviteShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?

    var allVoiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] {
        sections.flatMap(\.cells).reduce(into: [:]) { result, item in
            guard case .messages(let group) = item else { return }
            result.merge(group.voiceMemoTranscripts) { _, new in new }
        }
    }

    private lazy var layoutDelegate: DefaultMessagesLayoutDelegate = DefaultMessagesLayoutDelegate(sections: sections,
                                                                                                   oldSections: [])

    private func registerCells(in collectionView: UICollectionView) {
        collectionView.register(MessagesListItemTypeCell.self,
                                forCellWithReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier)

        collectionView.register(TypingIndicatorCollectionCell.self,
                                forCellWithReuseIdentifier: TypingIndicatorCollectionCell.reuseIdentifier)
    }
}

extension MessagesCollectionViewDataSource: MessagesCollectionDataSource {
    func prepare(with collectionView: UICollectionView) {
        registerCells(in: collectionView)
    }
}

extension MessagesCollectionViewDataSource: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].cells.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = sections[indexPath.section].cells[indexPath.item]
        let config = CellConfig(
            conversationId: conversationId,
            onTapInvite: { [weak self] invite in
                Log.debug("Tapped invite: \(invite)")
                self?.onTapInvite?(invite)
            },
            inviteMembershipResolver: inviteMembershipResolver,
            agentShareResolver: agentShareResolver,
            onTapAgentShare: { [weak self] agentShare in
                self?.onTapAgentShare?(agentShare)
            },
            onTapAvatar: { [weak self] message in
                self?.onTapAvatar?(message.sender)
            },
            onTapSender: { [weak self] member in
                self?.onTapAvatar?(member)
            },
            onTapReactions: { [weak self] message in
                self?.onTapReactions?(message)
            },
            onTapReadReceipts: { [weak self] group in
                self?.onTapReadReceipts?(group)
            },
            onTapThinkingIndicator: { [weak self] descriptor in
                self?.onTapThinkingIndicator?(descriptor)
            },
            onReaction: { [weak self] emoji, messageId in
                self?.onReaction?(emoji, messageId)
            },
            onToggleReaction: { [weak self] emoji, messageId in
                self?.onToggleReaction?(emoji, messageId)
            },
            onReply: { [weak self] message in
                self?.onReply?(message)
            },
            onOpenMessageDetail: onOpenMessageDetail.map { _ in
                { [weak self] message in self?.onOpenMessageDetail?(message) }
            },
            expandedMessageIds: expandedMessageIds,
            onToggleMessageExpanded: { [weak self] messageId in
                self?.onToggleMessageExpanded?(messageId)
            },
            contextMenuState: contextMenuState ?? .init(),
            onAgentOutOfCredits: { [weak self] in
                self?.onAgentOutOfCredits?()
            },
            creditsDepleted: creditsDepleted,
            onRetryAgentJoin: { [weak self] in
                self?.onRetryAgentJoin?()
            },
            onPhotoDimensionsLoaded: { [weak self] attachmentKey, width, height in
                self?.onPhotoDimensionsLoaded?(attachmentKey, width, height)
            },
            onTapUpdateMember: { [weak self] member in
                self?.onTapUpdateMember?(member)
            },
            onTapCapabilityConnect: { [weak self] prompt in
                self?.onTapCapabilityConnect?(prompt)
            },
            onOpenFile: { [weak self] attachment, message in
                self?.onOpenFile?(attachment, message)
            },
            onRetryMessage: { [weak self] message in
                self?.onRetryMessage?(message)
            },
            onDeleteMessage: { [weak self] message in
                self?.onDeleteMessage?(message)
            },
            onCopyInviteLink: { [weak self] in
                self?.onCopyInviteLink?()
            },
            onConvoCode: { [weak self] in
                self?.onConvoCode?()
            },
            onInviteAgent: { [weak self] in
                self?.onInviteAgent?()
            },
            onRetryTranscript: { [weak self] item in
                self?.onRetryTranscript?(item)
            },
            allVoiceMemoTranscripts: allVoiceMemoTranscripts,
            isAgentJoinPending: isAgentJoinPending,
            headerMode: headerMode,
            hidesInviteCard: hidesInviteCard,
            agentBuilderTransitionNamespace: agentBuilderTransitionNamespace,
            htmlAttachmentTransitionNamespace: htmlAttachmentTransitionNamespace,
            memberContactOverride: { [weak self] inboxId in
                self?.memberContactOverride?(inboxId)
            },
            agentBuilderSummaryProvider: agentBuilderSummaryProvider,
            currentUserProfileImage: currentUserProfileImage,
            backwardsSecrecyInfoSheet: backwardsSecrecyInfoSheet,
            showsInviteScanCard: showsInviteScanCard,
            inviteScanConversation: inviteScanConversation,
            inviteScanMode: inviteScanMode,
            inviteScanInitialSegment: inviteScanInitialSegment,
            onScannedInviteCode: { [weak self] code in
                self?.onScannedInviteCode?(code)
            },
            onInviteShareCompleted: { [weak self] activityType, completed, error in
                self?.onInviteShareCompleted?(activityType, completed, error)
            }
        )
        return CellFactory.createCell(
            in: collectionView,
            for: indexPath,
            with: item,
            config: config
        )
    }
}

extension MessagesCollectionViewDataSource: MessagesLayoutDelegate {
    func shouldPresentHeader(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool {
        layoutDelegate.shouldPresentHeader(messagesLayout, at: sectionIndex)
    }

    func shouldPresentFooter(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool {
        layoutDelegate.shouldPresentFooter(messagesLayout, at: sectionIndex)
    }

    func sizeForItem(_ messagesLayout: MessagesCollectionLayout,
                     of kind: ItemKind,
                     at indexPath: IndexPath) -> ItemSize {
        layoutDelegate.sizeForItem(messagesLayout, of: kind, at: indexPath)
    }

    func alignmentForItem(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          at indexPath: IndexPath) -> MessagesListItemAlignment {
        layoutDelegate.alignmentForItem(messagesLayout, of: kind, at: indexPath)
    }

    func initialLayoutAttributesForInsertedItem(_ messagesLayout: MessagesCollectionLayout,
                                                of kind: ItemKind,
                                                at indexPath: IndexPath,
                                                modifying originalAttributes: MessagesLayoutAttributes,
                                                on state: InitialAttributesRequestType) {
        layoutDelegate.initialLayoutAttributesForInsertedItem(messagesLayout,
                                                              of: kind,
                                                              at: indexPath,
                                                              modifying: originalAttributes,
                                                              on: state)
    }

    func finalLayoutAttributesForDeletedItem(_ messagesLayout: MessagesCollectionLayout,
                                             of kind: ItemKind,
                                             at indexPath: IndexPath,
                                             modifying originalAttributes: MessagesLayoutAttributes) {
        layoutDelegate.finalLayoutAttributesForDeletedItem(messagesLayout,
                                                           of: kind,
                                                           at: indexPath,
                                                           modifying: originalAttributes)
    }

    func interItemSpacing(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          after indexPath: IndexPath) -> CGFloat? {
        layoutDelegate.interItemSpacing(messagesLayout, of: kind, after: indexPath)
    }

    func interSectionSpacing(_ messagesLayout: MessagesCollectionLayout,
                             after sectionIndex: Int) -> CGFloat? {
        layoutDelegate.interSectionSpacing(messagesLayout, after: sectionIndex)
    }
}
#endif
