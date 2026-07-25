import ConvosComposer
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

    func configure(
        with conversation: Conversation,
        isSelected: Bool,
        memberContactOverride: @escaping @Sendable (String) -> Contact? = { _ in nil }
    ) {
        if let wrapper = hostingWrapper {
            wrapper.update(conversation: conversation, isSelected: isSelected, memberContactOverride: memberContactOverride)
        } else {
            let wrapper = ConversationListItemWrapper(
                conversation: conversation,
                isSelected: isSelected,
                memberContactOverride: memberContactOverride
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

    // Deliberately no `prepareForReuse` override clearing `contentConfiguration`
    // / `hostingWrapper`. `configure(with:)` runs synchronously on every dequeue
    // and reconfigure (see the cell registration in
    // `ConversationsViewController.makeDataSource`); keeping the wrapper lets it
    // take the cheap `wrapper.update(...)` path (an in-place observable mutation)
    // instead of rebuilding a fresh `UIHostingConfiguration` for every recycled
    // row. Clearing them on reuse defeated that fast path and forced a hosting
    // teardown plus a self-sizing re-measurement on every scroll recycle.
}

@Observable
@MainActor
final class ConversationListItemWrapper {
    var conversation: Conversation
    var isSelected: Bool
    var isSwiped: Bool = false
    var isHighlighted: Bool = false
    // Held on the wrapper (not injected once at build time) so a recycled cell
    // applies the latest resolver: `configure(with:)` reuses this wrapper via
    // `update(...)`, and the view controller reassigns its
    // `memberContactOverride` when contacts load, so a build-time injection
    // would leave reused rows resolving names/avatars through a stale closure.
    var memberContactOverride: @Sendable (String) -> Contact?

    init(
        conversation: Conversation,
        isSelected: Bool,
        memberContactOverride: @escaping @Sendable (String) -> Contact?
    ) {
        self.conversation = conversation
        self.isSelected = isSelected
        self.memberContactOverride = memberContactOverride
    }

    func update(
        conversation: Conversation,
        isSelected: Bool,
        memberContactOverride: @escaping @Sendable (String) -> Contact?
    ) {
        self.conversation = conversation
        self.isSelected = isSelected
        self.memberContactOverride = memberContactOverride
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
            .memberContactOverride(wrapper.memberContactOverride)
    }
}
