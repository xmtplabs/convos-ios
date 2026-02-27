import Combine
import ConvosCore
import SwiftUI
import UIKit

final class ConversationsViewController: UIViewController {
    // MARK: - Types

    struct State {
        var pinnedConversations: [Conversation]
        var unpinnedConversations: [Conversation]
        var selectedConversationId: String?
        var isFilteredResultEmpty: Bool
        var filterEmptyMessage: String
        var hasCreatedMoreThanOneConvo: Bool
        var horizontalSizeClass: UserInterfaceSizeClass?

        var shouldShowEmptyCTA: Bool {
            unpinnedConversations.count == 1 &&
            !hasCreatedMoreThanOneConvo &&
            horizontalSizeClass == .compact
        }

        static let empty: State = State(
            pinnedConversations: [],
            unpinnedConversations: [],
            selectedConversationId: nil,
            isFilteredResultEmpty: false,
            filterEmptyMessage: "",
            hasCreatedMoreThanOneConvo: false,
            horizontalSizeClass: nil
        )
    }

    enum Item: Hashable {
        case pinned(Conversation)
        case conversation(Conversation)
        case emptyCTA
        case filteredEmpty(String)

        func hash(into hasher: inout Hasher) {
            switch self {
            case .pinned(let conversation):
                hasher.combine("pinned")
                hasher.combine(conversation.id)
            case .conversation(let conversation):
                hasher.combine("conversation")
                hasher.combine(conversation.id)
            case .emptyCTA:
                hasher.combine("emptyCTA")
            case .filteredEmpty(let message):
                hasher.combine("filteredEmpty")
                hasher.combine(message)
            }
        }

        static func == (lhs: Item, rhs: Item) -> Bool {
            switch (lhs, rhs) {
            case let (.pinned(lConv), .pinned(rConv)):
                return lConv.id == rConv.id
            case let (.conversation(lConv), .conversation(rConv)):
                return lConv.id == rConv.id
            case (.emptyCTA, .emptyCTA):
                return true
            case let (.filteredEmpty(lMsg), .filteredEmpty(rMsg)):
                return lMsg == rMsg
            default:
                return false
            }
        }
    }

    // MARK: - Properties

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ConversationsSection, Item>!
    private var currentState: State = .empty
    private var colorScheme: UIUserInterfaceStyle = .light

    // MARK: - Callbacks

    var onSelectConversation: ((Conversation) -> Void)?
    var onDeleteConversation: ((Conversation) -> Void)?
    var onExplodeConversation: ((Conversation) -> Void)?
    var onToggleMute: ((Conversation) -> Void)?
    var onToggleReadState: ((Conversation) -> Void)?
    var onTogglePin: ((Conversation) -> Void)?
    var onStartConvo: (() -> Void)?
    var onJoinConvo: (() -> Void)?
    var onShowAllFilter: (() -> Void)?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupDataSource()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            colorScheme = traitCollection.userInterfaceStyle
        }
    }

    // MARK: - Public API

    func updateState(_ state: State) {
        let oldPinnedCount = currentState.pinnedConversations.count
        let newPinnedCount = state.pinnedConversations.count
        let selectionChanged = currentState.selectedConversationId != state.selectedConversationId
        currentState = state

        // Recreate layout if pinned count changed (affects layout style)
        if oldPinnedCount != newPinnedCount || layoutNeedsRecreation(oldCount: oldPinnedCount, newCount: newPinnedCount) {
            collectionView.setCollectionViewLayout(createLayout(), animated: false)
        }

        applySnapshot(animated: true)

        // Reconfigure visible cells if selection changed (to update background)
        if selectionChanged {
            reconfigureVisibleCells()
        }
    }

    private func reconfigureVisibleCells() {
        var snapshot = dataSource.snapshot()
        let itemsToReconfigure = snapshot.itemIdentifiers.filter { item in
            switch item {
            case .conversation, .pinned:
                return true
            case .emptyCTA, .filteredEmpty:
                return false
            }
        }
        snapshot.reconfigureItems(itemsToReconfigure)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Private Setup

    private func layoutNeedsRecreation(oldCount: Int, newCount: Int) -> Bool {
        // Layout changes at these thresholds: 0, 1, 2, 3+
        let oldBucket = min(oldCount, 3)
        let newBucket = min(newCount, 3)
        return oldBucket != newBucket
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: createLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .automatic

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Register cells
        collectionView.register(PinnedConversationCell.self, forCellWithReuseIdentifier: PinnedConversationCell.cellReuseIdentifier)
        collectionView.register(EmptyStateCell.self, forCellWithReuseIdentifier: EmptyStateCell.cellReuseIdentifier)
    }

    private func createLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self = self else { return nil }

            // Determine section based on current state and index
            // If pinned is empty, only list exists at index 0
            // If pinned has items, pinned is at 0 and list is at 1
            let hasPinnedSection = !self.currentState.pinnedConversations.isEmpty

            if hasPinnedSection {
                if sectionIndex == 0 {
                    return self.createPinnedSectionLayout(environment: environment)
                } else {
                    return self.createListSectionLayout(environment: environment)
                }
            } else {
                // No pinned section, only list at index 0
                return self.createListSectionLayout(environment: environment)
            }
        }
    }

    private func createPinnedSectionLayout(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        let itemCount = currentState.pinnedConversations.count
        guard itemCount > 0 else { return nil }

        let spacing: CGFloat = DesignConstants.Spacing.step6x
        let horizontalPadding: CGFloat = DesignConstants.Spacing.step6x

        if itemCount < 3 {
            return createHorizontalPinnedSection(
                itemCount: itemCount,
                spacing: spacing,
                horizontalPadding: horizontalPadding,
                environment: environment
            )
        } else {
            return createGridPinnedSection(
                spacing: spacing,
                horizontalPadding: horizontalPadding,
                environment: environment
            )
        }
    }

    private func createHorizontalPinnedSection(
        itemCount: Int,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        let containerWidth = environment.container.effectiveContentSize.width
        let availableWidth = containerWidth - (horizontalPadding * 2)

        // Fixed item width for pinned tiles
        let itemWidth: CGFloat = 100

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(itemWidth),
            heightDimension: .estimated(130)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        // Calculate total group width
        let totalItemsWidth = CGFloat(itemCount) * itemWidth + CGFloat(itemCount - 1) * spacing
        let groupWidth = min(totalItemsWidth, availableWidth)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(groupWidth),
            heightDimension: .estimated(130)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            subitems: Array(repeating: item, count: itemCount)
        )
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: DesignConstants.Spacing.step3x,
            leading: (containerWidth - groupWidth) / 2, // Center the group
            bottom: DesignConstants.Spacing.step3x,
            trailing: (containerWidth - groupWidth) / 2
        )

        return section
    }

    private func createGridPinnedSection(
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        let containerWidth = environment.container.effectiveContentSize.width
        let availableWidth = containerWidth - (horizontalPadding * 2)
        let itemWidth = (availableWidth - (spacing * 2)) / 3

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(itemWidth),
            heightDimension: .estimated(130)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(130)
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

    private func createListSectionLayout(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear

        // Leading swipe actions (Delete, Explode)
        configuration.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.leadingSwipeActions(for: indexPath)
        }

        // Trailing swipe actions (Read/Unread, Mute)
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(for: indexPath)
        }

        return NSCollectionLayoutSection.list(
            using: configuration,
            layoutEnvironment: environment
        )
    }

    private func setupDataSource() {
        // Cell registration for list items
        let listCellRegistration = UICollectionView.CellRegistration<ConversationListItemCell, Conversation> { [weak self] cell, _, conversation in
            guard let self = self else { return }
            let isSelected = self.currentState.selectedConversationId == conversation.id
            let isCompact = self.currentState.horizontalSizeClass == .compact
            cell.configure(with: conversation, isSelected: isSelected, isCompact: isCompact)
        }

        // Cell registration for pinned items
        let pinnedCellRegistration = UICollectionView.CellRegistration<PinnedConversationCell, Conversation> { [weak self] cell, _, conversation in
            guard let self = self else { return }
            let isSelected = self.currentState.selectedConversationId == conversation.id
            let isCompact = self.currentState.horizontalSizeClass == .compact
            cell.configure(with: conversation, isSelected: isSelected, isCompact: isCompact)
        }

        // Cell registration for empty states
        let emptyCellRegistration = UICollectionView.CellRegistration<EmptyStateCell, EmptyStateType> { cell, _, type in
            cell.configure(with: type)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            guard let self = self else { return nil }

            switch item {
            case .pinned(let conversation):
                return collectionView.dequeueConfiguredReusableCell(
                    using: pinnedCellRegistration,
                    for: indexPath,
                    item: conversation
                )

            case .conversation(let conversation):
                return collectionView.dequeueConfiguredReusableCell(
                    using: listCellRegistration,
                    for: indexPath,
                    item: conversation
                )

            case .emptyCTA:
                let type = EmptyStateType.cta(
                    onStartConvo: { self.onStartConvo?() },
                    onJoinConvo: { self.onJoinConvo?() }
                )
                return collectionView.dequeueConfiguredReusableCell(
                    using: emptyCellRegistration,
                    for: indexPath,
                    item: type
                )

            case .filteredEmpty(let message):
                let type = EmptyStateType.filtered(
                    message: message,
                    onShowAll: { self.onShowAllFilter?() }
                )
                return collectionView.dequeueConfiguredReusableCell(
                    using: emptyCellRegistration,
                    for: indexPath,
                    item: type
                )
            }
        }
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<ConversationsSection, Item>()

        // Pinned section
        if !currentState.pinnedConversations.isEmpty {
            snapshot.appendSections([.pinned])
            let pinnedItems = currentState.pinnedConversations.map { Item.pinned($0) }
            snapshot.appendItems(pinnedItems, toSection: .pinned)
        }

        // List section
        snapshot.appendSections([.list])

        if currentState.isFilteredResultEmpty {
            snapshot.appendItems([.filteredEmpty(currentState.filterEmptyMessage)], toSection: .list)
        } else {
            // Add empty CTA before first conversation if needed
            if currentState.shouldShowEmptyCTA {
                snapshot.appendItems([.emptyCTA], toSection: .list)
            }

            let listItems = currentState.unpinnedConversations.map { Item.conversation($0) }
            snapshot.appendItems(listItems, toSection: .list)
        }

        dataSource.apply(snapshot, animatingDifferences: animated)

        // Restore selection after applying snapshot
        updateSelection()
    }

    private func updateSelection() {
        guard let selectedId = currentState.selectedConversationId else {
            // Clear selection if no conversation is selected
            collectionView.indexPathsForSelectedItems?.forEach { indexPath in
                collectionView.deselectItem(at: indexPath, animated: false)
            }
            return
        }

        // Find the index path for the selected conversation
        let snapshot = dataSource.snapshot()
        for (sectionIndex, section) in snapshot.sectionIdentifiers.enumerated() {
            let items = snapshot.itemIdentifiers(inSection: section)
            for (itemIndex, item) in items.enumerated() {
                let conversationId: String?
                switch item {
                case .pinned(let conversation), .conversation(let conversation):
                    conversationId = conversation.id
                case .emptyCTA, .filteredEmpty:
                    conversationId = nil
                }

                if conversationId == selectedId {
                    let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
                    if collectionView.indexPathsForSelectedItems?.contains(indexPath) != true {
                        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                    }
                    return
                }
            }
        }
    }

    // MARK: - Swipe Actions

    private func leadingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .conversation(let conversation) = item else {
            return nil
        }

        var actions: [UIContextualAction] = []

        // Delete action
        let deleteAction = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
            self?.onDeleteConversation?(conversation)
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        deleteAction.backgroundColor = UIColor(named: "colorCaution") ?? .systemRed
        actions.append(deleteAction)

        // Explode action (only for creators of non-pending conversations)
        if !conversation.isPendingInvite && conversation.creator.isCurrentUser {
            let explodeAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
                self?.onExplodeConversation?(conversation)
                completion(true)
            }
            explodeAction.image = UIImage(systemName: "burst")
            explodeAction.backgroundColor = colorScheme == .dark ? .white : .black
            actions.append(explodeAction)
        }

        let config = UISwipeActionsConfiguration(actions: actions)
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .conversation(let conversation) = item,
              !conversation.isPendingInvite else {
            return nil
        }

        var actions: [UIContextualAction] = []

        // Mute/Unmute action
        let muteAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
            self?.onToggleMute?(conversation)
            completion(true)
        }
        muteAction.image = UIImage(systemName: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
        muteAction.backgroundColor = UIColor(named: "colorPurpleMute") ?? .systemPurple
        actions.append(muteAction)

        // Read/Unread action
        let readAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
            self?.onToggleReadState?(conversation)
            completion(true)
        }
        readAction.image = UIImage(systemName: conversation.isUnread ? "checkmark.message.fill" : "message.badge.fill")
        readAction.backgroundColor = colorScheme == .dark ? .white : .black
        actions.append(readAction)

        let config = UISwipeActionsConfiguration(actions: actions)
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    // MARK: - Helpers

    private func conversation(for indexPath: IndexPath) -> Conversation? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch item {
        case .pinned(let conversation), .conversation(let conversation):
            return conversation
        case .emptyCTA, .filteredEmpty:
            return nil
        }
    }
}

// MARK: - UICollectionViewDelegate

extension ConversationsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        guard let conversation = conversation(for: indexPath) else { return }
        onSelectConversation?(conversation)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let conversation = conversation(for: indexPath) else { return nil }

        return UIContextMenuConfiguration(identifier: indexPath as NSCopying, previewProvider: nil) { [weak self] _ in
            self?.createContextMenu(for: conversation)
        }
    }

    private func createContextMenu(for conversation: Conversation) -> UIMenu {
        var actions: [UIMenuElement] = []

        // Quick actions row (Fav/Unfav, Read/Unread, Mute/Unmute)
        var quickActions: [UIAction] = []

        // Pin/Unpin
        let pinTitle = conversation.isPinned ? "Unfav" : "Fav"
        let pinImage = UIImage(systemName: conversation.isPinned ? "star.slash.fill" : "star.fill")
        let pinAction = UIAction(title: pinTitle, image: pinImage) { [weak self] _ in
            self?.onTogglePin?(conversation)
        }
        quickActions.append(pinAction)

        // Read/Unread (not for pending invites)
        if !conversation.isPendingInvite {
            let readTitle = conversation.isUnread ? "Read" : "Unread"
            let readImage = UIImage(systemName: conversation.isUnread ? "message" : "message.badge")
            let readAction = UIAction(title: readTitle, image: readImage) { [weak self] _ in
                self?.onToggleReadState?(conversation)
            }
            quickActions.append(readAction)

            // Mute/Unmute
            let muteTitle = conversation.isMuted ? "Unmute" : "Mute"
            let muteImage = UIImage(systemName: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
            let muteAction = UIAction(title: muteTitle, image: muteImage) { [weak self] _ in
                self?.onToggleMute?(conversation)
            }
            quickActions.append(muteAction)
        }

        let quickMenu = UIMenu(title: "", options: .displayInline, children: quickActions)
        actions.append(quickMenu)

        // Explode (only for creators of non-pending conversations)
        if !conversation.isPendingInvite && conversation.creator.isCurrentUser {
            let explodeAction = UIAction(
                title: "Explode",
                subtitle: "For everyone",
                image: UIImage(systemName: "burst")
            ) { [weak self] _ in
                self?.onExplodeConversation?(conversation)
            }
            let explodeMenu = UIMenu(title: "", options: .displayInline, children: [explodeAction])
            actions.append(explodeMenu)
        }

        // Delete
        let deleteAction = UIAction(
            title: "Delete",
            subtitle: "For me",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.onDeleteConversation?(conversation)
        }
        let deleteMenu = UIMenu(title: "", options: .displayInline, children: [deleteAction])
        actions.append(deleteMenu)

        return UIMenu(title: "", children: actions)
    }
}
