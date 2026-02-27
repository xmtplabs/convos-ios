import ConvosCore
import SwiftUI
import UIKit

final class PinnedConversationCell: UICollectionViewCell {
    static let cellReuseIdentifier: String = "PinnedConversationCell"

    private var conversation: Conversation?
    private var isItemSelected: Bool = false

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
        updateContentConfiguration()

        accessibilityIdentifier = "pinned-conversation-\(conversation.id)"
        accessibilityLabel = "\(conversation.displayName), pinned"
        isAccessibilityElement = true
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        updateContentConfiguration()
    }

    private func updateContentConfiguration() {
        guard let conversation = conversation else { return }

        contentConfiguration = UIHostingConfiguration {
            PinnedConversationItem(conversation: conversation)
        }
        .margins(.all, 0)
        .background(.clear)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let targetSize = CGSize(
            width: layoutAttributes.size.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let fittingSize = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        layoutAttributes.size.height = fittingSize.height
        return layoutAttributes
    }
}
