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

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        hostingWrapper = nil
    }

    func configure(
        with conversation: Conversation,
        isSelected: Bool,
        memberContactOverride: @escaping @Sendable (String) -> Contact? = { _ in nil }
    ) {
        if let wrapper = hostingWrapper {
            wrapper.update(conversation: conversation, isSelected: isSelected)
        } else {
            let wrapper = PinnedConversationWrapper(conversation: conversation, isSelected: isSelected)
            hostingWrapper = wrapper
            contentConfiguration = UIHostingConfiguration {
                PinnedConversationWrapperView(wrapper: wrapper)
                    .memberContactOverride(memberContactOverride)
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

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var avatarSize: CGFloat {
        if isPhone {
            return 96
        }
        return 72
    }

    private var verticalPadding: CGFloat {
        if isPhone {
            return 0
        }
        return DesignConstants.Spacing.step2x
    }

    var body: some View {
        PinnedConversationItem(conversation: wrapper.conversation, avatarSize: avatarSize)
            .padding(.vertical, verticalPadding)
    }
}
