import ConvosCore
import SwiftUI
import UIKit

final class PinnedConversationCell: UICollectionViewCell {
    static let cellReuseIdentifier: String = "PinnedConversationCell"

    private var hostingWrapper: PinnedConversationWrapper?

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
        hostingWrapper = nil
    }

    func configure(with conversation: Conversation, isSelected: Bool, isCompact: Bool) {
        if let wrapper = hostingWrapper {
            wrapper.update(conversation: conversation)
        } else {
            let wrapper = PinnedConversationWrapper(conversation: conversation)
            hostingWrapper = wrapper
            contentConfiguration = UIHostingConfiguration {
                PinnedConversationWrapperView(wrapper: wrapper)
            }
            .margins(.all, 0)
            .background(.clear)
        }

        accessibilityIdentifier = "pinned-conversation-\(conversation.id)"
        accessibilityLabel = "\(conversation.displayName), pinned"
        isAccessibilityElement = true
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

@Observable
@MainActor
final class PinnedConversationWrapper {
    var conversation: Conversation

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    func update(conversation: Conversation) {
        self.conversation = conversation
    }
}

struct PinnedConversationWrapperView: View {
    @State var wrapper: PinnedConversationWrapper

    var body: some View {
        PinnedConversationItem(conversation: wrapper.conversation)
    }
}
