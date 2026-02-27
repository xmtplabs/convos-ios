import ConvosCore
import SwiftUI
import UIKit

final class ConversationListItemCell: UICollectionViewListCell {
    private var conversation: Conversation?
    private var isItemSelected: Bool = false
    private var isCompact: Bool = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        conversation = nil
        isItemSelected = false
    }

    func configure(with conversation: Conversation, isSelected: Bool, isCompact: Bool) {
        self.conversation = conversation
        self.isItemSelected = isSelected
        self.isCompact = isCompact
        updateContentConfiguration()

        accessibilityIdentifier = conversation.isPendingInvite
            ? "conversation-list-item-draft-\(conversation.id)"
            : "conversation-list-item-\(conversation.id)"
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        updateContentConfiguration()
    }

    private func updateContentConfiguration() {
        guard let conversation = conversation else { return }

        // On iPhone (compact), don't show persistent selection - just show momentary highlight
        // On iPad (regular), show persistent selection with rounded corners
        let shouldHighlight = !isCompact && isItemSelected

        contentConfiguration = UIHostingConfiguration {
            ConversationsListItem(conversation: conversation)
        }
        .margins(.all, 0)
        .background {
            if shouldHighlight {
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                    .fill(Color(.systemGray5))
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
            } else {
                Color.clear
            }
        }
    }
}
