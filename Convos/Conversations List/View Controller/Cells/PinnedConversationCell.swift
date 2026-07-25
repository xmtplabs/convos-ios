import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

final class PinnedConversationCell: UICollectionViewCell {
    static let cellReuseIdentifier: String = "PinnedConversationCell"

    private var hostingWrapper: PinnedConversationWrapper?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.clipsToBounds = false
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    // Deliberately no `prepareForReuse` override clearing the hosting wrapper:
    // `configure(with:)` reuses it via the in-place `wrapper.update(...)` path on
    // recycle instead of rebuilding the `UIHostingConfiguration`. See the
    // matching note in `ConversationListItemCell`.

    func configure(
        with conversation: Conversation,
        isSelected: Bool,
        memberContactOverride: @escaping @Sendable (String) -> Contact? = { _ in nil }
    ) {
        if let wrapper = hostingWrapper {
            wrapper.update(conversation: conversation, isSelected: isSelected, memberContactOverride: memberContactOverride)
        } else {
            let wrapper = PinnedConversationWrapper(
                conversation: conversation,
                isSelected: isSelected,
                memberContactOverride: memberContactOverride
            )
            hostingWrapper = wrapper
            contentConfiguration = UIHostingConfiguration {
                PinnedConversationWrapperView(wrapper: wrapper)
            }
            .margins(.all, 0)
            .background(.clear)
        }

        updateSelectionBackground(isSelected: isSelected)

        accessibilityIdentifier = "pinned-conversation-\(conversation.id)"
        let resolvedName = conversation.computedDisplayName(memberNameOverride: { memberContactOverride($0)?.displayName })
        accessibilityLabel = "\(resolvedName), pinned"
        isAccessibilityElement = true
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
    // Held on the wrapper so reuse applies the latest resolver - see the note
    // in `ConversationListItemWrapper`.
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

struct PinnedConversationWrapperView: View {
    var wrapper: PinnedConversationWrapper

    private var avatarSize: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 96 : 72
    }

    var body: some View {
        PinnedConversationItem(conversation: wrapper.conversation, avatarSize: avatarSize)
            .padding(.vertical, UIDevice.current.userInterfaceIdiom == .phone ? 0 : DesignConstants.Spacing.step2x)
            .memberContactOverride(wrapper.memberContactOverride)
    }
}
