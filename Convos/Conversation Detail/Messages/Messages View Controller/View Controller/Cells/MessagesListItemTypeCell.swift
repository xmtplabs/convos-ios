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

    override func prepareForReuse() {
        super.prepareForReuse()
        self.contentConfiguration = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if Self.debugMode {
            debugHeightLabel.text = "H:\(Int(bounds.height))"
            debugHeightLabel.superview?.bringSubviewToFront(debugHeightLabel)
        }
    }

    func setup(item: MessagesListItemType, config: CellConfig) {
        contentConfiguration = UIHostingConfiguration {
            Group {
                switch item {
                case .date(let dateGroup):
                    TextTitleContentView(title: dateGroup.value, profile: nil)
                        .id(dateGroup.differenceIdentifier)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .update(_, let update, _):
                    VStack(spacing: 0) {
                        TextTitleContentView(
                            title: update.summary,
                            profile: update.profile,
                            agentVerification: update.profileMember?.agentVerification ?? .unverified,
                            onTap: update.profileMember.map { member in
                                { config.onTapUpdateMember(member) }
                            }
                        )
                            .id(update.differenceIdentifier)
                            .padding(.top, DesignConstants.Spacing.step4x)
                            .padding(.bottom, update.addedVerifiedAssistant ? DesignConstants.Spacing.step3x : DesignConstants.Spacing.step4x)
                            .padding(.horizontal, DesignConstants.Spacing.step4x)
                        if update.addedVerifiedAssistant {
                            AssistantJoinedInfoView()
                                .padding(.horizontal, DesignConstants.Spacing.step4x)
                        }
                    }

                case .messages(let group):
                    MessagesGroupView(
                        group: group,
                        conversationId: config.conversationId,
                        shouldBlurPhotos: config.shouldBlurPhotos,
                        onTapAvatar: config.onTapAvatar,
                        onTapInvite: config.onTapInvite,
                        onTapReactions: config.onTapReactions,
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
                        allVoiceMemoTranscripts: config.allVoiceMemoTranscripts
                    )

                case .invite(let invite):
                    VStack(spacing: DesignConstants.Spacing.step4x) {
                        InviteView(invite: invite)
                        NewConvoIdentityView(
                            onCopyLink: config.onCopyInviteLink,
                            onConvoCode: config.onConvoCode,
                            onInviteAssistant: config.onInviteAssistant,
                            hasAssistant: config.hasAssistant,
                            isAssistantJoinPending: config.isAssistantJoinPending,
                            isAssistantEnabled: config.isAssistantEnabled
                        )
                    }
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .conversationInfo(let conversation):
                    VStack(spacing: DesignConstants.Spacing.step4x) {
                        ConversationInfoPreview(conversation: conversation)
                    }
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .agentOutOfCredits(let profile):
                    TextTitleContentView(
                        title: "\(profile.displayName) is out of processing power",
                        profile: profile,
                        onTap: config.onAgentOutOfCredits
                    )
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case let .assistantJoinStatus(status, requesterName, _):
                    AssistantJoinStatusView(
                        status: status,
                        requesterName: requesterName,
                        onRetry: config.onRetryAssistantJoin
                    )
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)

                case let .assistantPresentInfo(agent, inviterName):
                    let isVerified = agent.agentVerification.isVerified
                    let label = isVerified ? "Assistant" : "Agent"
                    let title = inviterName.map { "\(label) is present · Invited by \($0)" } ?? "\(label) is present"
                    VStack(spacing: 0) {
                        TextTitleContentView(
                            title: title,
                            profile: agent.profile,
                            agentVerification: agent.agentVerification,
                            onTap: { config.onTapUpdateMember(agent) }
                        )
                            .padding(.top, DesignConstants.Spacing.step4x)
                            .padding(.bottom, isVerified ? DesignConstants.Spacing.step3x : DesignConstants.Spacing.step4x)
                            .padding(.horizontal, DesignConstants.Spacing.step4x)
                        if isVerified {
                            AssistantJoinedInfoView()
                                .padding(.horizontal, DesignConstants.Spacing.step4x)
                        }
                    }

                case .typingIndicator:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: item.alignment == .center ? .center : .leading)
            .id("message-cell-\(item.differenceIdentifier)")
            .environment(\.messageContextMenuState, config.contextMenuState)
        }
        .margins(.horizontal, 0.0)
        .margins(.vertical, 0.0)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributesForHorizontalFittingRequired(layoutAttributes)
    }
}
