import ConvosCore
import SwiftUI
import UIKit

final class PinnedConversationCell: UICollectionViewCell {
    static let cellReuseIdentifier: String = "PinnedConversationCell"

    private var hostingWrapper: PinnedConversationWrapper?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        contentView.clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        hostingWrapper = nil
    }

    func configure(with conversation: Conversation, isSelected: Bool) {
        if let wrapper = hostingWrapper {
            wrapper.update(conversation: conversation, isSelected: isSelected)
        } else {
            let wrapper = PinnedConversationWrapper(conversation: conversation, isSelected: isSelected)
            hostingWrapper = wrapper
            contentConfiguration = UIHostingConfiguration {
                PinnedConversationWrapperView(wrapper: wrapper)
            }
            .margins(.all, 0)
            .background(.clear)
        }

        updateSelectionBackground(isSelected: isSelected)

        accessibilityIdentifier = "pinned-conversation-\(conversation.id)"
        accessibilityLabel = "\(conversation.displayName), pinned"
        isAccessibilityElement = true
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return layoutAttributes
        }
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

    private func updateSelectionBackground(isSelected: Bool) {
        guard UIDevice.current.userInterfaceIdiom != .phone else { return }

        if isSelected {
            var bg = UIBackgroundConfiguration.clear()
            bg.cornerRadius = DesignConstants.CornerRadius.mediumLarge
            bg.backgroundColor = .colorFillMinimal
            backgroundConfiguration = bg
        } else {
            backgroundConfiguration = UIBackgroundConfiguration.clear()
        }
    }
}

@Observable
@MainActor
final class PinnedConversationWrapper {
    var conversation: Conversation
    var isSelected: Bool

    init(conversation: Conversation, isSelected: Bool) {
        self.conversation = conversation
        self.isSelected = isSelected
    }

    func update(conversation: Conversation, isSelected: Bool) {
        self.conversation = conversation
        self.isSelected = isSelected
    }
}

struct PinnedConversationWrapperView: View {
    var wrapper: PinnedConversationWrapper

    private var avatarSize: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 96 : 72
    }

    var body: some View {
        PinnedConversationItem(conversation: wrapper.conversation, avatarSize: avatarSize)
    }
}
