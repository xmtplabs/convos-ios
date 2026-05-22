import ConvosCore
import SwiftUI
import UIKit

enum EmptyStateType {
    case cta(onStartConvo: () -> Void, onJoinConvo: () -> Void)
    case filtered(message: String, onShowAll: () -> Void)
}

final class EmptyStateCell: UICollectionViewCell {
    static let cellReuseIdentifier: String = "EmptyStateCell"

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
    }

    func configure(with type: EmptyStateType) {
        switch type {
        case .cta:
            // The first-run "Pop-up private convos" card has been replaced
            // by an inline `AgentBuilderView` mounted at the `MainTabView`
            // level (gated on `ConversationsViewModel.isEmptyCTAActive`).
            // This cell still renders so the collection-view diff stays
            // happy, but it's intentionally empty — when the inline
            // builder is active the chats tab itself is swapped out, so
            // this branch is effectively only hit when the tab is briefly
            // re-mounted during the transition.
            contentConfiguration = UIHostingConfiguration { EmptyView() }
                .margins(.all, 0)
                .background(.clear)

        case let .filtered(message, onShowAll):
            contentConfiguration = UIHostingConfiguration {
                FilteredEmptyStateView(
                    message: message,
                    onShowAll: onShowAll
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DesignConstants.Spacing.step6x)
                .padding(.top, DesignConstants.Spacing.step6x)
            }
            .margins(.all, 0)
            .background(.clear)
        }
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
        layoutAttributes.size.height = max(fittingSize.height, 200)
        return layoutAttributes
    }
}
