import ConvosCore
import SwiftUI
import UIKit

class MessagesListItemTypeCell: UICollectionViewCell {
    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.contentConfiguration = nil
    }

    func setup(
        item: MessagesListItemType,
        onTapAvatar: @escaping ((AnyMessage) -> Void),
        onTapInvite: @escaping ((MessageInvite) -> Void)
    ) {
        contentConfiguration = UIHostingConfiguration {
            Group {
                switch item {
                case .date(let dateGroup):
                    TextTitleContentView(title: dateGroup.value, profile: nil)
                        .id(dateGroup.differenceIdentifier)
                        .padding(.vertical, DesignConstants.Spacing.step4x)

                case .update(_, let update, _):
                    TextTitleContentView(title: update.summary, profile: update.profile)
                        .id(update.differenceIdentifier)
                        .padding(.vertical, DesignConstants.Spacing.step4x)

                case .messages(let group):
                    MessagesGroupView(
                        group: group,
                        onTapMessage: { _ in },
                        onTapAvatar: onTapAvatar,
                        onTapInvite: onTapInvite
                    )

                case .invite(let invite):
                    InviteView(invite: invite)
                        .padding(.vertical, DesignConstants.Spacing.step4x)

                case .conversationInfo(let conversation):
                    ConversationInfoPreview(conversation: conversation)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                }
            }
            .frame(maxWidth: .infinity, alignment: item.alignment == .center ? .center : .leading)
            .id("message-cell-\(item.differenceIdentifier)")
        }
        .margins(.horizontal, 0.0)
        .margins(.vertical, 0.0)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributesForHorizontalFittingRequired(layoutAttributes)
    }
}
