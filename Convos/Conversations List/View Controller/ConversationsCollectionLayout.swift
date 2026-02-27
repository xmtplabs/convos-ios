import ConvosCore
import UIKit

enum ConversationsSection: Int, CaseIterable {
    case pinned
    case list
}

@MainActor
final class ConversationsCollectionLayout {
    static func createLayout(
        pinnedCount: Int,
        environment: NSCollectionLayoutEnvironment
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { sectionIndex, layoutEnvironment in
            guard let section = ConversationsSection(rawValue: sectionIndex) else {
                return nil
            }

            switch section {
            case .pinned:
                return createPinnedSection(itemCount: pinnedCount, environment: layoutEnvironment)
            case .list:
                return createListSection(environment: layoutEnvironment)
            }
        }
    }

    private static func createPinnedSection(
        itemCount: Int,
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection? {
        guard itemCount > 0 else { return nil }

        let spacing: CGFloat = DesignConstants.Spacing.step6x
        let horizontalPadding: CGFloat = DesignConstants.Spacing.step6x

        if itemCount < 3 {
            // Horizontal layout for 1-2 items
            return createHorizontalPinnedSection(
                itemCount: itemCount,
                spacing: spacing,
                horizontalPadding: horizontalPadding,
                environment: environment
            )
        } else {
            // Grid layout for 3+ items
            return createGridPinnedSection(
                spacing: spacing,
                horizontalPadding: horizontalPadding,
                environment: environment
            )
        }
    }

    private static func createHorizontalPinnedSection(
        itemCount: Int,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        // Calculate item width based on count
        let containerWidth = environment.container.effectiveContentSize.width
        let availableWidth = containerWidth - (horizontalPadding * 2)
        let itemWidth: CGFloat

        if itemCount == 1 {
            // Single item - use fixed size, centered
            itemWidth = 100
        } else {
            // Two items - split available width
            itemWidth = (availableWidth - spacing) / 2
        }

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(itemWidth),
            heightDimension: .estimated(120)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(120)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            subitems: Array(repeating: item, count: itemCount)
        )
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: DesignConstants.Spacing.step3x,
            leading: horizontalPadding,
            bottom: DesignConstants.Spacing.step3x,
            trailing: horizontalPadding
        )

        // Center the group horizontally
        section.orthogonalScrollingBehavior = .none

        return section
    }

    private static func createGridPinnedSection(
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        // 3-column grid
        let containerWidth = environment.container.effectiveContentSize.width
        let availableWidth = containerWidth - (horizontalPadding * 2)
        let itemWidth = (availableWidth - (spacing * 2)) / 3

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(itemWidth),
            heightDimension: .estimated(120)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(120)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            subitems: [item, item, item]
        )
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: DesignConstants.Spacing.step3x,
            leading: horizontalPadding,
            bottom: DesignConstants.Spacing.step3x,
            trailing: horizontalPadding
        )

        return section
    }

    private static func createListSection(
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear

        // Configure swipe actions
        configuration.leadingSwipeActionsConfigurationProvider = nil
        configuration.trailingSwipeActionsConfigurationProvider = nil

        let section = NSCollectionLayoutSection.list(
            using: configuration,
            layoutEnvironment: environment
        )

        return section
    }
}
