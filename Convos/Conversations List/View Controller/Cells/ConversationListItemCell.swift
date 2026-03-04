import ConvosCore
import SwiftUI
import UIKit

final class ConversationListItemCell: UICollectionViewListCell {
    private var hostingWrapper: ConversationListItemWrapper?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with conversation: Conversation, isSelected: Bool) {
        if let wrapper = hostingWrapper {
            wrapper.update(conversation: conversation, isSelected: isSelected)
        } else {
            let wrapper = ConversationListItemWrapper(
                conversation: conversation,
                isSelected: isSelected
            )
            hostingWrapper = wrapper
            contentConfiguration = UIHostingConfiguration {
                ConversationListItemWrapperView(wrapper: wrapper)
            }
            .margins(.all, 0)
            .background(.clear)
        }

        accessibilityIdentifier = conversation.isPendingInvite
            ? "conversation-list-item-draft-\(conversation.id)"
            : "conversation-list-item-\(conversation.id)"
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        hostingWrapper?.isSwiped = state.isSwiped
        hostingWrapper?.isHighlighted = state.isHighlighted

        var bg = UIBackgroundConfiguration.clear()
        bg.backgroundColor = .clear
        backgroundConfiguration = bg
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        hostingWrapper = nil
    }
}

@Observable
@MainActor
final class ConversationListItemWrapper {
    var conversation: Conversation
    var isSelected: Bool
    var isSwiped: Bool = false
    var isHighlighted: Bool = false

    init(conversation: Conversation, isSelected: Bool) {
        self.conversation = conversation
        self.isSelected = isSelected
    }

    func update(conversation: Conversation, isSelected: Bool) {
        self.conversation = conversation
        self.isSelected = isSelected
    }
}

struct ConversationListItemWrapperView: View {
    var wrapper: ConversationListItemWrapper

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var shouldHighlight: Bool {
        if isPhone {
            return wrapper.isSwiped || wrapper.isHighlighted
        }
        return wrapper.isSwiped || wrapper.isSelected
    }

    var body: some View {
        ConversationsListItem(conversation: wrapper.conversation)
            .background {
                if shouldHighlight {
                    if isPhone, wrapper.isHighlighted, !wrapper.isSwiped {
                        Rectangle()
                            .fill(Color.colorFillMinimal)
                    } else {
                        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                            .fill(Color.colorFillMinimal)
                            .padding(.horizontal, isPhone ? 0 : DesignConstants.Spacing.step3x)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: wrapper.isSwiped)
    }
}
