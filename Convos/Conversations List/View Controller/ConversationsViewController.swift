import Combine
import ConvosCore
import SwiftUI
import UIKit

@MainActor
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
            UIDevice.current.userInterfaceIdiom == .phone
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

    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: createLayout())
        cv.translatesAutoresizingMaskIntoConstraints = false
        cv.backgroundColor = .clear
        cv.clipsToBounds = false
        cv.delegate = self
        cv.alwaysBounceVertical = true
        cv.contentInsetAdjustmentBehavior = .automatic
        cv.allowsFocus = false
        cv.register(PinnedConversationCell.self, forCellWithReuseIdentifier: PinnedConversationCell.cellReuseIdentifier)
        cv.register(EmptyStateCell.self, forCellWithReuseIdentifier: EmptyStateCell.cellReuseIdentifier)
        return cv
    }()
    private lazy var dataSource: UICollectionViewDiffableDataSource<ConversationsSection, Item> = makeDataSource()
    private var currentState: State = .empty

    // MARK: - Callbacks

    var onSelectConversation: ((Conversation) -> Void)?
    var onConfirmedDeleteConversation: ((Conversation) -> Void)?
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
        _ = dataSource
    }

    // MARK: - Public API

    func updateState(_ state: State) {
        let oldState = currentState
        let oldPinnedIds = Set(oldState.pinnedConversations.map(\.id))
        let newPinnedIds = Set(state.pinnedConversations.map(\.id))
        let pinnedMembershipChanged = oldPinnedIds != newPinnedIds
        let selectionChanged = oldState.selectedConversationId != state.selectedConversationId
        currentState = state

        if layoutNeedsRecreation(oldCount: oldPinnedIds.count, newCount: newPinnedIds.count) {
            collectionView.setCollectionViewLayout(createLayout(), animated: false)
        }

        let changedIds = changedConversationIds(old: oldState, new: state, selectionChanged: selectionChanged)
        applySnapshot(animated: !pinnedMembershipChanged, changedIds: changedIds)
    }

    private func changedConversationIds(old: State, new: State, selectionChanged: Bool) -> Set<String> {
        let oldMap = Dictionary(
            uniqueKeysWithValues: (old.pinnedConversations + old.unpinnedConversations).map { ($0.id, $0) }
        )
        let newMap = Dictionary(
            uniqueKeysWithValues: (new.pinnedConversations + new.unpinnedConversations).map { ($0.id, $0) }
        )

        var changed = Set<String>()
        for (id, newConvo) in newMap {
            guard let oldConvo = oldMap[id] else {
                changed.insert(id)
                continue
            }
            if oldConvo.isMuted != newConvo.isMuted ||
                oldConvo.isUnread != newConvo.isUnread ||
                oldConvo.isPinned != newConvo.isPinned ||
                oldConvo.scheduledExplosionDate != newConvo.scheduledExplosionDate ||
                oldConvo.displayName != newConvo.displayName ||
                oldConvo.lastMessage != newConvo.lastMessage {
                changed.insert(id)
            }
        }

        if selectionChanged {
            if let id = old.selectedConversationId { changed.insert(id) }
            if let id = new.selectedConversationId { changed.insert(id) }
        }

        return changed
    }

    // MARK: - Private Setup

    private func layoutNeedsRecreation(oldCount: Int, newCount: Int) -> Bool {
        // Pinned section has three layout states:
        //   0 items: no pinned section
        //   1-2 items: horizontal centered row
        //   3+ items: 3-column grid
        let oldBucket = min(oldCount, 3)
        let newBucket = min(newCount, 3)
        return oldBucket != newBucket
    }

    private func setupCollectionView() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func createLayout() -> UICollectionViewLayout {
        ConversationsCompositionalLayout { [weak self] sectionIndex, environment in
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

        let isIPad = UIDevice.current.userInterfaceIdiom != .phone
        let spacing: CGFloat = isIPad ? DesignConstants.Spacing.step3x : DesignConstants.Spacing.step6x
        let horizontalPadding: CGFloat = isIPad ? DesignConstants.Spacing.step4x : DesignConstants.Spacing.step6x

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

        let isIPad = UIDevice.current.userInterfaceIdiom != .phone
        let itemWidth: CGFloat = isIPad ? 80 : 100

        let itemHeight: CGFloat = isIPad ? 116 : 130
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(itemWidth),
            heightDimension: .absolute(itemHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        // Calculate total group width
        let totalItemsWidth = CGFloat(itemCount) * itemWidth + CGFloat(itemCount - 1) * spacing
        let groupWidth = min(totalItemsWidth, availableWidth)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .absolute(groupWidth),
            heightDimension: .absolute(itemHeight)
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
        let isIPad = UIDevice.current.userInterfaceIdiom != .phone
        let itemHeight: CGFloat = isIPad ? 116 : 130

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(itemWidth),
            heightDimension: .absolute(itemHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(itemHeight)
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

    private func freshConversation(for conversation: Conversation) -> Conversation {
        if let fresh = currentState.pinnedConversations.first(where: { $0.id == conversation.id }) {
            return fresh
        }
        if let fresh = currentState.unpinnedConversations.first(where: { $0.id == conversation.id }) {
            return fresh
        }
        return conversation
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<ConversationsSection, Item> {
        // Cell registration for list items
        let listCellRegistration = UICollectionView.CellRegistration<ConversationListItemCell, Conversation> { [weak self] cell, _, conversation in
            guard let self = self else { return }
            let fresh = self.freshConversation(for: conversation)
            let isSelected = self.currentState.selectedConversationId == fresh.id
            cell.configure(with: fresh, isSelected: isSelected)
        }

        // Cell registration for pinned items
        let pinnedCellRegistration = UICollectionView.CellRegistration<PinnedConversationCell, Conversation> { [weak self] cell, _, conversation in
            guard let self = self else { return }
            let fresh = self.freshConversation(for: conversation)
            let isSelected = self.currentState.selectedConversationId == fresh.id
            cell.configure(with: fresh, isSelected: isSelected)
        }

        // Cell registration for empty states
        let emptyCellRegistration = UICollectionView.CellRegistration<EmptyStateCell, EmptyStateType> { cell, _, type in
            cell.configure(with: type)
        }

        return UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
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

    private func applySnapshot(animated: Bool, changedIds: Set<String>) {
        var snapshot = NSDiffableDataSourceSnapshot<ConversationsSection, Item>()

        if !currentState.pinnedConversations.isEmpty {
            snapshot.appendSections([.pinned])
            let pinnedItems = currentState.pinnedConversations.map { Item.pinned($0) }
            snapshot.appendItems(pinnedItems, toSection: .pinned)
        }

        snapshot.appendSections([.list])

        if currentState.isFilteredResultEmpty {
            snapshot.appendItems([.filteredEmpty(currentState.filterEmptyMessage)], toSection: .list)
        } else {
            if currentState.shouldShowEmptyCTA {
                snapshot.appendItems([.emptyCTA], toSection: .list)
            }

            let listItems = currentState.unpinnedConversations.map { Item.conversation($0) }
            snapshot.appendItems(listItems, toSection: .list)
        }

        dataSource.apply(snapshot, animatingDifferences: animated)

        if !changedIds.isEmpty {
            var applied = dataSource.snapshot()
            let itemsToReconfigure = applied.itemIdentifiers.filter { item in
                switch item {
                case .pinned(let c), .conversation(let c):
                    return changedIds.contains(c.id)
                case .emptyCTA, .filteredEmpty:
                    return false
                }
            }
            if !itemsToReconfigure.isEmpty {
                applied.reconfigureItems(itemsToReconfigure)
                dataSource.apply(applied, animatingDifferences: false)
            }
        }

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

    // MARK: - Helpers

    private func cellForConversation(_ conversation: Conversation) -> UIView? {
        let snapshot = dataSource.snapshot()
        for item in snapshot.itemIdentifiers {
            let matchesId: Bool
            switch item {
            case .pinned(let c), .conversation(let c):
                matchesId = c.id == conversation.id
            case .emptyCTA, .filteredEmpty:
                matchesId = false
            }
            if matchesId, let indexPath = dataSource.indexPath(for: item) {
                return collectionView.cellForItem(at: indexPath)
            }
        }
        return nil
    }

    // MARK: - Delete Confirmation

    private func showDeleteConfirmation(for conversation: Conversation, sourceView: UIView? = nil) {
        let alert = UIAlertController(
            title: "This convo will be deleted immediately.",
            message: nil,
            preferredStyle: .actionSheet
        )

        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.onConfirmedDeleteConversation?(conversation)
        }
        alert.addAction(deleteAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            let isPinned = currentState.pinnedConversations.contains { $0.id == conversation.id }
            let cell = cellForConversation(conversation) ?? sourceView ?? view
            popover.sourceView = cell
            popover.permittedArrowDirections = []
            if let cell {
                popover.sourceRect = CGRect(
                    x: cell.bounds.midX,
                    y: isPinned ? cell.bounds.maxY : cell.bounds.minY,
                    width: 0,
                    height: 0
                )
            }
        }

        present(alert, animated: true)
    }

    // MARK: - Swipe Actions

    private func leadingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .conversation(let conversation) = item else {
            return nil
        }

        var actions: [UIContextualAction] = []

        let deleteAction = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
            guard let self = self else { return completion(false) }
            let fresh = self.freshConversation(for: conversation)
            self.showDeleteConfirmation(for: fresh)
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        deleteAction.backgroundColor = UIColor(named: "colorCaution") ?? .systemRed
        actions.append(deleteAction)

        if !conversation.isPendingInvite && conversation.creator.isCurrentUser {
            let explodeAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
                guard let self = self else { return completion(false) }
                let fresh = self.freshConversation(for: conversation)
                self.onExplodeConversation?(fresh)
                completion(true)
            }
            explodeAction.image = UIImage(systemName: "burst")
            explodeAction.backgroundColor = traitCollection.userInterfaceStyle == .dark ? .white : .black
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

        let muteAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
            guard let self = self else { return completion(false) }
            let fresh = self.freshConversation(for: conversation)
            self.onToggleMute?(fresh)
            completion(true)
        }
        muteAction.image = UIImage(systemName: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
        muteAction.backgroundColor = UIColor(named: "colorPurpleMute") ?? .systemPurple
        actions.append(muteAction)

        let readAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
            guard let self = self else { return completion(false) }
            let fresh = self.freshConversation(for: conversation)
            self.onToggleReadState?(fresh)
            completion(true)
        }
        readAction.image = UIImage(systemName: conversation.isUnread ? "checkmark.message.fill" : "message.badge.fill")
        readAction.backgroundColor = traitCollection.userInterfaceStyle == .dark ? .white : .black
        actions.append(readAction)

        let config = UISwipeActionsConfiguration(actions: actions)
        config.performsFirstActionWithFullSwipe = false
        return config
    }
}

// MARK: - UICollectionViewDelegate

extension ConversationsViewController: UICollectionViewDelegate {
    private func conversation(for indexPath: IndexPath) -> Conversation? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch item {
        case .pinned(let conversation), .conversation(let conversation):
            return conversation
        case .emptyCTA, .filteredEmpty:
            return nil
        }
    }

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
        guard let item = dataSource.itemIdentifier(for: indexPath),
              let conversation = conversation(for: indexPath) else {
            return nil
        }

        let isPinned: Bool
        if case .pinned = item { isPinned = true } else { isPinned = false }

        let conversationId = conversation.id

        return UIContextMenuConfiguration(
            identifier: conversationId as NSCopying,
            previewProvider: isPinned ? { [weak self] in
                guard let self = self else { return nil }
                let fresh = self.freshConversation(for: conversation)
                let hostingController = UIHostingController(rootView:
                    PinnedConversationItem(conversation: fresh, animateOnAppear: false)
                        .frame(width: 96)
                        .scaleEffect(1.2)
                        .padding(DesignConstants.Spacing.step8x)
                )
                hostingController.view.backgroundColor = .systemBackground
                let size = hostingController.sizeThatFits(in: CGSize(width: 280, height: 500))
                hostingController.preferredContentSize = size
                return hostingController
            } : nil
        ) { [weak self] _ in
            guard let self = self else { return UIMenu(title: "", children: []) }
            let fresh = self.freshConversation(for: conversation)
            return self.createContextMenu(for: fresh)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        targetedPreview(for: configuration)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        targetedPreview(for: configuration)
    }

    private func targetedPreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let conversationId = configuration.identifier as? String else { return nil }

        let snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.pinned) else { return nil }

        let pinnedItem = snapshot.itemIdentifiers(inSection: .pinned).first { item in
            if case .pinned(let c) = item { return c.id == conversationId }
            return false
        }
        guard let item = pinnedItem,
              let indexPath = dataSource.indexPath(for: item),
              let cell = collectionView.cellForItem(at: indexPath) else {
            return nil
        }

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: cell, parameters: parameters)
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
            self?.showDeleteConfirmation(for: conversation)
        }
        let deleteMenu = UIMenu(title: "", options: .displayInline, children: [deleteAction])
        actions.append(deleteMenu)

        return UIMenu(title: "", children: actions)
    }
}
