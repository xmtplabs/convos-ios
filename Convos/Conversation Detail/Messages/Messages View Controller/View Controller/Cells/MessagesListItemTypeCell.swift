import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

class MessagesListItemTypeCell: UICollectionViewCell {
    // MARK: - Debug Mode
    // Set to true to show debug borders and height labels
    static let debugMode: Bool = false

    private let debugHeightLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .systemRed
        label.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.8)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupDebugViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDebugViews()
    }

    private func setupDebugViews() {
        guard Self.debugMode else { return }
        contentView.addSubview(debugHeightLabel)
        NSLayoutConstraint.activate([
            debugHeightLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            debugHeightLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            debugHeightLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])
        contentView.layer.borderColor = UIColor.systemBlue.cgColor
        contentView.layer.borderWidth = 2
    }

    // Deliberately no `prepareForReuse` override clearing `contentConfiguration`.
    // `setup(item:)` runs synchronously on every dequeue (see `CellFactory`) and
    // assigns a fresh `UIHostingConfiguration` of the same generic type, which
    // UIKit applies as an in-place update of the existing hosting controller
    // rather than a teardown-and-rebuild. Per-item SwiftUI state still resets
    // via the content's `.id("message-cell-\(differenceIdentifier)")`. Clearing
    // the configuration on reuse cost a measurable chunk of scroll time: a full
    // hosting teardown plus a fresh self-sizing measurement for every recycled
    // cell.

    override func layoutSubviews() {
        super.layoutSubviews()
        if Self.debugMode {
            debugHeightLabel.text = "H:\(Int(bounds.height))"
            debugHeightLabel.superview?.bringSubviewToFront(debugHeightLabel)
        }
    }

    func setup(item: MessagesListItemType, config: CellConfig) {
        // Top-anchor the hosting content (maxHeight + top alignment): when an
        // in-cell animation grows the content, the cell frame jumps to the
        // final height in one self-sizing invalidation while the SwiftUI
        // content is still mid-animation. A height-hugging root re-centers
        // in the taller bounds, shifting the visible rows down by half the
        // height delta for a few frames; pinning to the top leaves the
        // transient gap at the cell's bottom instead. Self-sizing
        // measurement is unaffected: it proposes an unspecified height,
        // where maxHeight .infinity still reports the content's ideal size.
        let rootAlignment: Alignment = item.alignment == .center ? .top : .topLeading
        contentConfiguration = UIHostingConfiguration {
            Group {
                switch item {
                case .date(let dateGroup):
                    TextTitleContentView(title: dateGroup.value, profile: nil)
                        .id(dateGroup.differenceIdentifier)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .update(_, let update, _):
                    UpdateCellContent(update: update, config: config)

                case .messages(let group):
                    MessagesListItemTypeCell.messagesGroupContent(group: group, config: config)

                case .invite(let invite):
                    VStack(spacing: DesignConstants.Spacing.step4x) {
                        if config.headerMode == .standard, !config.hidesInviteCard {
                            InviteView(invite: invite)
                        }
                        NewConvoIdentityView(
                            onCopyLink: config.onCopyInviteLink,
                            onConvoCode: config.onConvoCode,
                            onInviteAgent: config.onInviteAgent,
                            isAgentJoinPending: config.isAgentJoinPending
                        )
                    }
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .conversationInfo(let conversation):
                    VStack(spacing: DesignConstants.Spacing.step4x) {
                        ConversationInfoPreview(
                            conversation: conversation,
                            memberContactOverride: config.memberContactOverride
                        )
                    }
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case let .agentOutOfCredits(member, isCurrentUserCreator):
                    AgentLostPowerStatus(
                        agentName: member.profile.displayName,
                        isCreator: isCurrentUserCreator,
                        onUpgrade: config.onAgentOutOfCredits
                    )
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case let .agentJoinStatus(status, requesterName, _):
                    AgentJoinStatusView(
                        status: status,
                        requesterName: requesterName,
                        onRetry: config.onRetryAgentJoin
                    )
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case let .agentPresentInfo(agent, inviterName):
                    MessagesListItemTypeCell.agentPresentInfoContent(agent: agent, inviterName: inviterName, config: config)

                case let .connectionEvent(_, summary, _):
                    ConnectionEventSummaryView(summary: summary)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .agentBuilderSummary(let content):
                    AgentBuilderSummaryView(
                        content: content,
                        transitionNamespace: content.transitionEligible ? config.agentBuilderTransitionNamespace : nil
                    )
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .typingIndicator:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rootAlignment)
            .id("message-cell-\(item.differenceIdentifier)")
            .environment(\.messageContextMenuState, config.contextMenuState)
            .environment(\.agentShareResolver, config.agentShareResolver)
            .environment(\.inviteMembershipResolver, config.inviteMembershipResolver)
            .environment(\.onTapAgentShare, config.onTapAgentShare)
        }
        .margins(.horizontal, 0.0)
        .margins(.vertical, 0.0)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributesForHorizontalFittingRequired(layoutAttributes)
    }

    // MARK: - Extracted cases
    //
    // The two cases below were lifted out of `setup`'s @ViewBuilder switch
    // because their argument lists trip the long-function-body type-check
    // budget when inlined. Mirrors the same shape as the `MessagesGroupView`
    // extraction noted in PR #930.

    @ViewBuilder
    fileprivate static func messagesGroupContent(group: MessagesGroup, config: CellConfig) -> some View {
        MessagesGroupView(
            group: group,
            conversationId: config.conversationId,
            shouldBlurPhotos: config.shouldBlurPhotos,
            onTapAvatar: config.onTapAvatar,
            onTapSender: config.onTapSender,
            onTapInvite: config.onTapInvite,
            onTapReactions: config.onTapReactions,
            onTapReadReceipts: config.onTapReadReceipts,
            onTapThinkingIndicator: config.onTapThinkingIndicator,
            onReaction: config.onReaction,
            onToggleReaction: config.onToggleReaction,
            onReply: config.onReply,
            onPhotoRevealed: config.onPhotoRevealed,
            onPhotoHidden: config.onPhotoHidden,
            onPhotoDimensionsLoaded: config.onPhotoDimensionsLoaded,
            onOpenFile: config.onOpenFile,
            onRetryMessage: config.onRetryMessage,
            onDeleteMessage: config.onDeleteMessage,
            onRetryTranscript: config.onRetryTranscript,
            allVoiceMemoTranscripts: config.allVoiceMemoTranscripts,
            htmlAttachmentTransitionNamespace: config.htmlAttachmentTransitionNamespace,
            creditsDepleted: config.creditsDepleted
        )
    }

    @ViewBuilder
    fileprivate static func agentPresentInfoContent(
        agent: ConversationMember,
        inviterName: String?,
        config: CellConfig
    ) -> some View {
        let label: String = "Agent"
        let title: String = inviterName.map { "\(label) is present · Invited by \($0)" } ?? "\(label) is present"
        VStack(spacing: 0) {
            TextTitleContentView(
                title: title,
                profile: agent.profile,
                agentVerification: agent.agentVerification,
                onTap: { config.onTapUpdateMember(agent) }
            )
                .padding(.top, DesignConstants.Spacing.step4x)
                .padding(.bottom, DesignConstants.Spacing.step4x)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }
}

/// Renders a single `.update` cell (system row). Extracted from
/// `MessagesListItemTypeCell.setup`'s switch so
/// the function body stays under the 125-line SwiftLint cap; the body
/// here also substitutes the contact's profile for the per-conversation
/// profile when the inbox is a known contact, so a row like "Alice
/// joined" renders Alice's actual avatar instead of an "S" monogram
/// derived from the placeholder per-conversation profile.
private struct UpdateCellContent: View {
    let update: ConversationUpdate
    let config: CellConfig

    var body: some View {
        let nameResolver: (String) -> String? = { config.memberContactOverride($0)?.displayName }
        let resolvedProfile: Profile? = update.profile.map { profile in
            config.memberContactOverride(profile.inboxId)
                .map { profile.overlaying(contact: $0) } ?? profile
        }
        VStack(spacing: 0) {
            TextTitleContentView(
                title: update.summary(memberNameOverride: nameResolver),
                profile: resolvedProfile,
                agentVerification: update.profileMember?.agentVerification ?? .unverified,
                onTap: update.profileMember.map { member in
                    { config.onTapUpdateMember(member) }
                }
            )
                .id(update.differenceIdentifier)
                .padding(.top, DesignConstants.Spacing.step4x)
                .padding(.bottom, DesignConstants.Spacing.step4x)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }
}
