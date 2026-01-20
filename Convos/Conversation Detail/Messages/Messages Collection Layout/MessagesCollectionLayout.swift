import Foundation
import UIKit

// swiftlint:disable force_cast force_unwrapping type_body_length no_assertions

open class MessagesCollectionLayout: UICollectionViewLayout {
    weak var delegate: MessagesLayoutDelegate?

    var settings: MessagesLayoutSettings = MessagesLayoutSettings() {
        didSet {
            guard collectionView != nil,
                  settings != oldValue else {
                return
            }
            invalidateLayout()
        }
    }

    var keepContentOffsetAtBottomOnBatchUpdates: Bool = false
    var processOnlyVisibleItemsOnAnimatedBatchUpdates: Bool = true

    var supportSelfSizingInvalidation: Bool {
        get {
            _supportSelfSizingInvalidation
        }
        set {
            _supportSelfSizingInvalidation = newValue
        }
    }

    open var visibleBounds: CGRect {
        guard let collectionView else {
            return .zero
        }
        return CGRect(x: adjustedContentInset.left,
                      y: collectionView.contentOffset.y + adjustedContentInset.top,
                      width: collectionView.bounds.width - adjustedContentInset.left - adjustedContentInset.right,
                      height: collectionView.bounds.height - adjustedContentInset.top - adjustedContentInset.bottom)
    }

    open var layoutFrame: CGRect {
        guard let collectionView else {
            return .zero
        }
        let additionalInsets = settings.additionalInsets
        return CGRect(
            x: adjustedContentInset.left + additionalInsets.left,
            y: adjustedContentInset.top + additionalInsets.top,
            width: collectionView.bounds.width - additionalInsets.left
            - additionalInsets.right - adjustedContentInset.left - adjustedContentInset.right,
            height: controller.contentHeight(at: state) - additionalInsets.top - additionalInsets.bottom
            - adjustedContentInset.top - adjustedContentInset.bottom
        )
    }

    open override var developmentLayoutDirection: UIUserInterfaceLayoutDirection {
        .leftToRight
    }

    open override var flipsHorizontallyInOppositeLayoutDirection: Bool {
        _flipsHorizontallyInOppositeLayoutDirection
    }

    open override class var layoutAttributesClass: AnyClass {
        MessagesLayoutAttributes.self
    }

    open override class var invalidationContextClass: AnyClass {
        MessagesLayoutInvalidationContext.self
    }

    open override var collectionViewContentSize: CGSize {
        let contentSize: CGSize
        if state == .beforeUpdate {
            contentSize = controller.contentSize(for: .beforeUpdate)
        } else {
            contentSize = controller.contentSize(for: .afterUpdate)
        }
        return contentSize
    }

    // MARK: Internal Properties

    var adjustedContentInset: UIEdgeInsets {
        guard let collectionView else {
            return .zero
        }
        return collectionView.adjustedContentInset
    }

    var viewSize: CGSize {
        guard let collectionView else {
            return .zero
        }
        return collectionView.frame.size
    }

    // MARK: Private Properties

    private struct PrepareActions: OptionSet {
        let rawValue: UInt

        static let recreateSectionModels: PrepareActions = PrepareActions(rawValue: 1 << 0)
        static let updateLayoutMetrics: PrepareActions = PrepareActions(rawValue: 1 << 1)
        static let cachePreviousWidth: PrepareActions = PrepareActions(rawValue: 1 << 2)
        static let cachePreviousContentInsets: PrepareActions = PrepareActions(rawValue: 1 << 3)
        static let switchStates: PrepareActions = PrepareActions(rawValue: 1 << 4)
    }

    private struct InvalidationActions: OptionSet {
        let rawValue: UInt

        static let shouldInvalidateOnBoundsChange: InvalidationActions = InvalidationActions(rawValue: 1 << 0)
    }

    private lazy var controller: MessagesLayoutStateController = .init(layoutRepresentation: self)
    private var state: MessagesCollectionLayoutModelState = .beforeUpdate
    private var prepareActions: PrepareActions = []
    private var invalidationActions: InvalidationActions = []
    private var cachedCollectionViewSize: CGSize?
    private var cachedCollectionViewInset: UIEdgeInsets?
    private var contentOffsetBeforeUpdate: CGPoint?

    // These properties are used to keep the layout attributes copies used for insert/delete
    // animations up-to-date as items are self-sized. If we don't keep these copies up-to-date, then
    // animations will start from the estimated height.
    private var attributesForPendingAnimations: [ItemKind: [ItemPath: MessagesLayoutAttributes]] = [:]

    private var invalidatedAttributes: [ItemKind: Set<ItemPath>] = [:]
    private var dontReturnAttributes: Bool = true
    private var currentPositionSnapshot: MessagesLayoutPositionSnapshot?
    private let _flipsHorizontallyInOppositeLayoutDirection: Bool
    private var reconfigureItemsIndexPaths: [IndexPath] = []
    private var _supportSelfSizingInvalidation: Bool = false

    var hasPinnedHeaderOrFooter: Bool = false

    // MARK: Constructors

    init(flipsHorizontallyInOppositeLayoutDirection: Bool = true) {
        _flipsHorizontallyInOppositeLayoutDirection = flipsHorizontallyInOppositeLayoutDirection
        super.init()
        resetAttributesForPendingAnimations()
        resetInvalidatedAttributes()
    }

    public required init?(coder aDecoder: NSCoder) {
        _flipsHorizontallyInOppositeLayoutDirection = true
        super.init(coder: aDecoder)
        resetAttributesForPendingAnimations()
        resetInvalidatedAttributes()
    }

    func getContentOffsetSnapshot(from edge: MessagesLayoutPositionSnapshot.Edge) -> MessagesLayoutPositionSnapshot? {
        guard let collectionView else {
            return nil
        }
        let insets = UIEdgeInsets(top: -collectionView.frame.height,
                                  left: 0,
                                  bottom: -collectionView.frame.height,
                                  right: 0)
        let visibleBounds = visibleBounds
        let layoutAttributes = controller.layoutAttributesForElements(in: visibleBounds.inset(by: insets),
                                                                      state: state,
                                                                      ignoreCache: true)
            .sorted(by: { $0.frame.maxY < $1.frame.maxY })

        switch edge {
        case .top:
            let firstVisibleItemAttributes = layoutAttributes
                .first(where: { $0.frame.minY >= visibleBounds.higherPoint.y })
            guard let firstVisibleItemAttributes = firstVisibleItemAttributes else { return nil }
            let visibleBoundsTopOffset = firstVisibleItemAttributes.frame.minY
            - visibleBounds.higherPoint.y - settings.additionalInsets.top
            return MessagesLayoutPositionSnapshot(indexPath: firstVisibleItemAttributes.indexPath,
                                                  kind: firstVisibleItemAttributes.kind,
                                                  edge: .top,
                                                  offset: visibleBoundsTopOffset)
        case .bottom:
            let lastVisibleItemAttributes = layoutAttributes
                .last(where: { $0.frame.minY <= visibleBounds.lowerPoint.y })
            guard let lastVisibleItemAttributes = lastVisibleItemAttributes else {
                return nil
            }
            let visibleBoundsBottomOffset = visibleBounds.lowerPoint.y - lastVisibleItemAttributes.frame.maxY
            - settings.additionalInsets.bottom
            return MessagesLayoutPositionSnapshot(indexPath: lastVisibleItemAttributes.indexPath,
                                                  kind: lastVisibleItemAttributes.kind,
                                                  edge: .bottom,
                                                  offset: visibleBoundsBottomOffset)
        }
    }

    func restoreContentOffset(with snapshot: MessagesLayoutPositionSnapshot) {
        guard let collectionView else {
            return
        }

        // We do not want to return attributes while we just looking for a position so that `UICollectionView` wont
        // create unnecessary cells that may not be used when we find the actual position.
        dontReturnAttributes = true
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        currentPositionSnapshot = snapshot
        let context = MessagesLayoutInvalidationContext()
        context.invalidateLayoutMetrics = false
        invalidateLayout(with: context)

        dontReturnAttributes = false
        collectionView.setNeedsLayout()
        collectionView.layoutIfNeeded()
        currentPositionSnapshot = nil
    }

    open func reconfigureItems(at indexPaths: [IndexPath]) {
        reconfigureItemsIndexPaths = indexPaths
    }

    // MARK: Providing Layout Attributes

    open override func prepare() {
        super.prepare()

        guard let collectionView,
              !prepareActions.isEmpty else {
            return
        }

        if prepareActions.contains(.switchStates) {
            controller.commitUpdates()
            state = .beforeUpdate
            resetAttributesForPendingAnimations()
            resetInvalidatedAttributes()
            contentOffsetBeforeUpdate = nil
        }

        if prepareActions.contains(.updateLayoutMetrics) || prepareActions.contains(.recreateSectionModels) {
            hasPinnedHeaderOrFooter = false
        }

        if prepareActions.contains(.recreateSectionModels) {
            var sections: ContiguousArray<SectionModel<MessagesCollectionLayout>> = []
            for sectionIndex in 0..<collectionView.numberOfSections {
                // Header
                let header: ItemModel?
                if delegate?.shouldPresentHeader(self, at: sectionIndex) == true {
                    let headerPath = IndexPath(item: 0, section: sectionIndex)
                    header = ItemModel(with: configuration(for: .header, at: headerPath))
                } else {
                    header = nil
                }

                // Items
                var items: ContiguousArray<ItemModel> = []
                for itemIndex in 0..<collectionView.numberOfItems(inSection: sectionIndex) {
                    let itemPath = IndexPath(item: itemIndex, section: sectionIndex)
                    items.append(ItemModel(with: configuration(for: .cell, at: itemPath)))
                }

                // Footer
                let footer: ItemModel?
                if delegate?.shouldPresentFooter(self, at: sectionIndex) == true {
                    let footerPath = IndexPath(item: 0, section: sectionIndex)
                    footer = ItemModel(with: configuration(for: .footer, at: footerPath))
                } else {
                    footer = nil
                }
                var section = SectionModel(interSectionSpacing: interSectionSpacing(at: sectionIndex),
                                           header: header,
                                           footer: footer,
                                           items: items,
                                           collectionLayout: self)
                section.assembleLayout()
                sections.append(section)
            }
            controller.set(sections, at: .beforeUpdate)
        }

        if prepareActions.contains(.updateLayoutMetrics),
           !prepareActions.contains(.recreateSectionModels) {
            var sections: ContiguousArray<SectionModel> = controller.layout(at: state).sections
            sections.withUnsafeMutableBufferPointer { directlyMutableSections in
                for sectionIndex in 0..<directlyMutableSections.count {
                    var section = directlyMutableSections[sectionIndex]

                    // Header
                    if var header = section.header {
                        header.resetSize()
                        section.set(header: header)
                    }

                    // Items
                    var items: ContiguousArray<ItemModel> = section.items
                    items.withUnsafeMutableBufferPointer { directlyMutableItems in
                        nonisolated(unsafe) let directlyMutableItems = directlyMutableItems
                        DispatchQueue.concurrentPerform(iterations: directlyMutableItems.count) { rowIndex in
                            directlyMutableItems[rowIndex].resetSize()
                        }
                    }
                    section.set(items: items)

                    // Footer
                    if var footer = section.footer {
                        footer.resetSize()
                        section.set(footer: footer)
                    }

                    section.assembleLayout()
                    directlyMutableSections[sectionIndex] = section
                }
            }
            controller.set(sections, at: state)
        }

        if prepareActions.contains(.cachePreviousContentInsets) {
            cachedCollectionViewInset = adjustedContentInset
        }

        if prepareActions.contains(.cachePreviousWidth) {
            cachedCollectionViewSize = collectionView.bounds.size
        }

        prepareActions = []
    }

    open override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // This early return prevents an issue that causes overlapping / misplaced elements after an
        // off-screen batch update occurs. The root cause of this issue is that `UICollectionView`
        // expects `layoutAttributesForElementsInRect:` to return post-batch-update layout attributes
        // immediately after an update is sent to the collection view via the insert/delete/reload/move
        // functions. Unfortunately, this is impossible - when batch updates occur, `invalidateLayout:`
        // is invoked immediately with a context that has `invalidateDataSourceCounts` set to `true`.
        // At this time, `MessagesCollectionLayout` has no way of knowing the details of this data source count
        // change (where the insert/delete/move took place). `MessagesCollectionLayout` only gets this additional
        // information once `prepareForCollectionViewUpdates:` is invoked. At that time, we're able to
        // update our layout's source of truth, the `StateController`, which allows us to resolve the
        // post-batch-update layout and return post-batch-update layout attributes from this function.
        // Between the time that `invalidateLayout:` is invoked with `invalidateDataSourceCounts` set to
        // `true`, and when `prepareForCollectionViewUpdates:` is invoked with details of the updates,
        // `layoutAttributesForElementsInRect:` is invoked with the expectation that we already have a
        // fully resolved layout. If we return incorrect layout attributes at that time, then we'll have
        // overlapping elements / visual defects. To prevent this, we can return `nil` in this
        // situation, which works around the bug.
        // `UICollectionViewCompositionalLayout`, in classic UIKit fashion, avoids this bug / feature by
        // implementing the private function
        // `_prepareForCollectionViewUpdates:withDataSourceTranslator:`, which provides the layout with
        // details about the updates to the collection view before `layoutAttributesForElementsInRect:`
        // is invoked, enabling them to resolve their layout in time.
        guard !dontReturnAttributes else {
            return nil
        }

        let visibleAttributes = controller.layoutAttributesForElements(in: rect, state: state)
        return visibleAttributes
    }

    /// Retrieves layout information for an item at the specified index path with a corresponding cell.
    open override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard !dontReturnAttributes else {
            return nil
        }
        let attributes = controller.itemAttributes(for: indexPath.itemPath, kind: .cell, at: state)
        return attributes
    }

    /// Retrieves the layout attributes for the specified supplementary view.
    open override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard !dontReturnAttributes else {
            return nil
        }

        guard let kind = ItemKind(elementKind) else {
            return nil
        }

        return controller.itemAttributes(for: indexPath.itemPath, kind: kind, at: state)
    }

    // MARK: Coordinating Animated Changes

    open override func prepare(forAnimatedBoundsChange oldBounds: CGRect) {
        controller.isAnimatedBoundsChange = true
        controller.process(changeItems: [])
        state = .afterUpdate
        prepareActions.remove(.switchStates)
        guard let collectionView,
              oldBounds.width != collectionView.bounds.width,
              keepContentOffsetAtBottomOnBatchUpdates,
              controller.isLayoutBiggerThanVisibleBounds(at: state) else {
            return
        }
        let newBounds = collectionView.bounds
        let heightDifference = oldBounds.height - newBounds.height
        controller.proposedCompensatingOffset += heightDifference + (oldBounds.origin.y - newBounds.origin.y)
    }

    open override func finalizeAnimatedBoundsChange() {
        if controller.isAnimatedBoundsChange {
            state = .beforeUpdate
            resetInvalidatedAttributes()
            resetAttributesForPendingAnimations()
            controller.commitUpdates()
            controller.isAnimatedBoundsChange = false
            controller.proposedCompensatingOffset = 0
            controller.batchUpdateCompensatingOffset = 0
        }
    }

    // MARK: Context Invalidation

    open override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        let preferredAttributesItemPath = preferredAttributes.indexPath.itemPath
        guard
            let preferredMessageAttributes = preferredAttributes as? MessagesLayoutAttributes,
            let item = controller.item(for: preferredAttributesItemPath,
                                       kind: preferredMessageAttributes.kind,
                                       at: state)
        else {
            return true
        }

        let shouldInvalidateLayout = item.calculatedSize == nil
        || (_supportSelfSizingInvalidation
            ? (item.size.height - preferredMessageAttributes.size.height).rounded() != 0 : false)
        || item.alignment != preferredMessageAttributes.alignment
        || item.interItemSpacing != preferredMessageAttributes.interItemSpacing

        return shouldInvalidateLayout
    }

    open override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        guard let preferredMessageAttributes = preferredAttributes as? MessagesLayoutAttributes,
              // Can be called after the model update in iOS <16. Checking if model for this index path exists.
              controller.item(for: preferredMessageAttributes.indexPath.itemPath, kind: .cell, at: state) != nil else {
            return super.invalidationContext(forPreferredLayoutAttributes: preferredAttributes,
                                             withOriginalAttributes: originalAttributes)
        }

        let preferredAttributesItemPath = preferredMessageAttributes.indexPath.itemPath

        if state == .afterUpdate {
            invalidatedAttributes[preferredMessageAttributes.kind]?.insert(preferredAttributesItemPath)
        }

        let layoutAttributesForPendingAnimation =
        attributesForPendingAnimations[preferredMessageAttributes.kind]?[preferredAttributesItemPath]

        let newItemSize = itemSize(with: preferredMessageAttributes)
        let newItemAlignment = alignment(for: preferredMessageAttributes.kind,
                                         at: preferredMessageAttributes.indexPath)
        let newInterItemSpacing = interItemSpacing(for: preferredMessageAttributes.kind,
                                                   at: preferredMessageAttributes.indexPath)
        controller.update(preferredSize: newItemSize,
                          alignment: newItemAlignment,
                          interItemSpacing: newInterItemSpacing,
                          for: preferredAttributesItemPath,
                          kind: preferredMessageAttributes.kind,
                          at: state)

        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredMessageAttributes,
            withOriginalAttributes: originalAttributes
        ) as! MessagesLayoutInvalidationContext

        let heightDifference = newItemSize.height - originalAttributes.size.height
        let isAboveBottomEdge = originalAttributes.frame.minY.rounded() <= visibleBounds.maxY.rounded()

        if heightDifference != 0,
           (keepContentOffsetAtBottomOnBatchUpdates
            && controller.contentHeight(at: state).rounded() + heightDifference > visibleBounds.height.rounded())
            || isUserInitiatedScrolling,
           isAboveBottomEdge {
            let offsetCompensation: CGFloat = min(
                controller.contentHeight(at: state) - collectionView!.frame.height
                + adjustedContentInset.bottom + adjustedContentInset.top,
                heightDifference
            )
            context.contentOffsetAdjustment.y += offsetCompensation
            invalidationActions.formUnion([.shouldInvalidateOnBoundsChange])
        }

        if let attributes = controller.itemAttributes(for: preferredAttributesItemPath,
                                                      kind: preferredMessageAttributes.kind, at: state)?.typedCopy() {
            layoutAttributesForPendingAnimation?.frame = attributes.frame
            if state == .afterUpdate {
                controller.totalProposedCompensatingOffset += heightDifference
                controller.offsetByTotalCompensation(attributes: layoutAttributesForPendingAnimation,
                                                     for: state, backward: true)
                if controller.insertedIndexes.contains(preferredMessageAttributes.indexPath) ||
                    controller.insertedSectionsIndexes.contains(preferredMessageAttributes.indexPath.section) {
                    layoutAttributesForPendingAnimation.map { attributes in
                        guard let delegate else {
                            attributes.alpha = 0
                            return
                        }
                        delegate.initialLayoutAttributesForInsertedItem(self, of: .cell, at: attributes.indexPath,
                                                                        modifying: attributes, on: .invalidation)
                    }
                }
            }
        } else {
            layoutAttributesForPendingAnimation?.frame.size = newItemSize
        }

        switch preferredMessageAttributes.kind {
        case .cell:
            context.invalidateItems(at: [preferredMessageAttributes.indexPath])
        case .footer, .header:
            if let type = preferredMessageAttributes.kind.supplementaryElementStringType {
                context.invalidateSupplementaryElements(
                    ofKind: type,
                    at: [preferredMessageAttributes.indexPath]
                )
            }
        }

        context.invalidateLayoutMetrics = false

        return context
    }

    /// Asks the layout object if the new bounds require a layout update.
    open override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        let shouldInvalidateLayout = cachedCollectionViewSize != .some(newBounds.size) ||
        cachedCollectionViewInset != .some(adjustedContentInset) ||
        invalidationActions.contains(.shouldInvalidateOnBoundsChange)
        || (isUserInitiatedScrolling && state == .beforeUpdate)

        invalidationActions.remove(.shouldInvalidateOnBoundsChange)
        return shouldInvalidateLayout || hasPinnedHeaderOrFooter
    }

    open override
    func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let invalidationContext = super
            .invalidationContext(forBoundsChange: newBounds) as! MessagesLayoutInvalidationContext
        invalidationContext.invalidateLayoutMetrics = false
        return invalidationContext
    }

    open override
    // swiftlint:disable:next overridden_super_call
    func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        guard let collectionView else {
            super.invalidateLayout(with: context)
            return
        }

        guard let context = context as? MessagesLayoutInvalidationContext else {
            assertionFailure("`context` must be an instance of `MessagesLayoutInvalidationContext`.")
            return
        }

        controller.resetCachedAttributes()

        dontReturnAttributes = context.invalidateDataSourceCounts && !context.invalidateEverything

        if context.invalidateEverything {
            prepareActions.formUnion([.recreateSectionModels])
        }

        // Checking `cachedCollectionViewWidth != collectionView.bounds.size.width` is necessary
        // because the collection view's width can change without a `contentSizeAdjustment` occurring.
        if context.contentSizeAdjustment.width != 0 || cachedCollectionViewSize != collectionView.bounds.size {
            prepareActions.formUnion([.cachePreviousWidth])
        }

        if cachedCollectionViewInset != adjustedContentInset {
            prepareActions.formUnion([.cachePreviousContentInsets])
        }

        if context.invalidateLayoutMetrics, !context.invalidateDataSourceCounts {
            prepareActions.formUnion([.updateLayoutMetrics])
        }

        if let currentPositionSnapshot {
            let contentHeight = controller.contentHeight(at: state)
            if let frame = controller.itemFrame(for: currentPositionSnapshot.indexPath.itemPath,
                                                kind: currentPositionSnapshot.kind,
                                                at: state,
                                                isFinal: true),
               contentHeight != 0 {
                let adjustedContentInset: UIEdgeInsets = collectionView.adjustedContentInset
                let maxAllowed = max(
                    -adjustedContentInset.top,
                    contentHeight - collectionView.frame.height + adjustedContentInset.bottom
                )
                switch currentPositionSnapshot.edge {
                case .top:
                    let desiredOffset = max(
                        min(
                            maxAllowed,
                            frame.minY
                            - currentPositionSnapshot.offset
                            - adjustedContentInset.top
                            - settings.additionalInsets.top
                        ),
                        -adjustedContentInset.top
                    )
                    context.contentOffsetAdjustment.y = desiredOffset - collectionView.contentOffset.y
                case .bottom:
                    let desiredOffset = max(
                        min(
                            maxAllowed,
                            frame.maxY + currentPositionSnapshot.offset - collectionView.bounds.height
                            + adjustedContentInset.bottom + settings.additionalInsets.bottom
                        ),
                        -adjustedContentInset.top
                    )
                    context.contentOffsetAdjustment.y = desiredOffset - collectionView.contentOffset.y
                }
            }
        }
        super.invalidateLayout(with: context)
    }

    /// Retrieves the content offset to use after an animated layout update or change.
    open override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        if controller.proposedCompensatingOffset != 0,
           let collectionView {
            let minPossibleContentOffset = -collectionView.adjustedContentInset.top
            let newProposedContentOffset =
            CGPoint(
                x: proposedContentOffset.x,
                y: max(
                    minPossibleContentOffset, min(
                        collectionView.contentOffset.y + controller.proposedCompensatingOffset,
                        maxPossibleContentOffset.y
                    )
                )
            )
            invalidationActions.formUnion([.shouldInvalidateOnBoundsChange])
            controller.proposedCompensatingOffset = 0
            return newProposedContentOffset
        }
        return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
    }

    // MARK: Responding to Collection View Updates

    /// Notifies the layout object that the contents of the collection view are about to change.
    open override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        var changeItems = updateItems.compactMap { ChangeItem(with: $0) }
        changeItems.append(contentsOf: reconfigureItemsIndexPaths.map { .itemReconfigure(itemIndexPath: $0) })
        controller.process(changeItems: changeItems)
        state = .afterUpdate
        dontReturnAttributes = false
        contentOffsetBeforeUpdate = collectionView?.contentOffset
        if !reconfigureItemsIndexPaths.isEmpty,
           let collectionView {
            reconfigureItemsIndexPaths
                .filter {
                    collectionView.indexPathsForVisibleItems.contains($0) && !controller.reloadedIndexes.contains($0)
                }
                .forEach { indexPath in
                    let cell = collectionView.cellForItem(at: indexPath)

                    if let originalAttributes = controller.itemAttributes(for: indexPath.itemPath,
                                                                          kind: .cell, at: .beforeUpdate),
                       let preferredAttributes =
                        cell?.preferredLayoutAttributesFitting(
                            originalAttributes.typedCopy()
                        ) as? MessagesLayoutAttributes,
                       let itemIdentifierBeforeUpdate = controller.itemIdentifier(for: indexPath.itemPath,
                                                                                  kind: .cell, at: .beforeUpdate),
                       let indexPathAfterUpdate = controller.itemPath(by: itemIdentifierBeforeUpdate,
                                                                      kind: .cell, at: .afterUpdate)?.indexPath,
                       let itemAfterUpdate = controller.item(for: indexPathAfterUpdate.itemPath,
                                                             kind: .cell, at: .afterUpdate),
                       (itemAfterUpdate.size.height - preferredAttributes.size.height).rounded() != 0 {
                        originalAttributes.indexPath = indexPathAfterUpdate
                        preferredAttributes.indexPath = indexPathAfterUpdate
                        _ = invalidationContext(forPreferredLayoutAttributes: preferredAttributes,
                                                withOriginalAttributes: originalAttributes)
                    }
                }
            reconfigureItemsIndexPaths = []
        }

        super.prepare(forCollectionViewUpdates: updateItems)
    }

    open override func finalizeCollectionViewUpdates() {
        controller.proposedCompensatingOffset = 0

        if keepContentOffsetAtBottomOnBatchUpdates,
           controller.isLayoutBiggerThanVisibleBounds(at: state),
           controller.batchUpdateCompensatingOffset != 0,
           let collectionView {
            let compensatingOffset: CGFloat
            if controller.contentSize(for: .beforeUpdate).height > visibleBounds.size.height {
                compensatingOffset =
                controller.batchUpdateCompensatingOffset - min(
                    0, maxPossibleContentOffset.y - (contentOffsetBeforeUpdate?.y ?? 0)
                )
            } else {
                compensatingOffset = maxPossibleContentOffset.y - collectionView.contentOffset.y
            }
            controller.batchUpdateCompensatingOffset = 0
            let context = MessagesLayoutInvalidationContext()
            context.contentOffsetAdjustment.y = compensatingOffset
            invalidateLayout(with: context)
        } else {
            controller.batchUpdateCompensatingOffset = 0
            let context = MessagesLayoutInvalidationContext()
            invalidateLayout(with: context)
        }

        prepareActions.formUnion(.switchStates)
        super.finalizeCollectionViewUpdates()
    }

    // MARK: - Cell Appearance Animation

    open override
    func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        var attributes: MessagesLayoutAttributes?

        let itemPath = itemIndexPath.itemPath
        if state == .afterUpdate {
            if
                controller.insertedIndexes.contains(itemIndexPath)
                    || controller.insertedSectionsIndexes.contains(itemPath.section) {
                attributes = controller.itemAttributes(for: itemPath, kind: .cell, at: .afterUpdate)?.typedCopy()
                controller.offsetByTotalCompensation(attributes: attributes, for: state, backward: true)
                attributes.map { attributes in
                    guard let delegate else {
                        attributes.alpha = 0
                        return
                    }
                    delegate.initialLayoutAttributesForInsertedItem(self,
                                                                    of: .cell,
                                                                    at: itemIndexPath,
                                                                    modifying: attributes,
                                                                    on: .initial)
                }
                attributesForPendingAnimations[.cell]?[itemPath] = attributes
            } else if let itemIdentifier = controller.itemIdentifier(for: itemPath, kind: .cell, at: .afterUpdate),
                      let initialIndexPath = controller.itemPath(by: itemIdentifier, kind: .cell, at: .beforeUpdate) {
                attributes = controller.itemAttributes(
                    for: initialIndexPath,
                    kind: .cell,
                    at: .beforeUpdate
                )?.typedCopy() ?? MessagesLayoutAttributes(forCellWith: itemIndexPath)
                attributes?.indexPath = itemIndexPath
                if #unavailable(iOS 13.0) {
                    if controller.reloadedIndexes.contains(itemIndexPath)
                        || controller.reconfiguredIndexes.contains(itemIndexPath)
                        || controller.reloadedSectionsIndexes.contains(itemPath.section) {
                        // It is needed to position the new cell in the middle of the old cell on ios 12
                        attributesForPendingAnimations[.cell]?[itemPath] = attributes
                    }
                }
            } else {
                attributes = controller.itemAttributes(for: itemPath, kind: .cell, at: .beforeUpdate)
            }
        } else {
            attributes = controller.itemAttributes(for: itemPath, kind: .cell, at: .beforeUpdate)
        }

        return attributes
    }

    open override
    func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        var attributes: MessagesLayoutAttributes?

        let itemPath = itemIndexPath.itemPath
        if state == .afterUpdate {
            if controller.deletedIndexes.contains(itemIndexPath)
                || controller.deletedSectionsIndexes.contains(itemPath.section) {
                attributes = controller.itemAttributes(
                    for: itemPath,
                    kind: .cell,
                    at: .beforeUpdate)?.typedCopy() ?? MessagesLayoutAttributes(forCellWith: itemIndexPath)
                controller.offsetByTotalCompensation(attributes: attributes, for: state, backward: false)
                if keepContentOffsetAtBottomOnBatchUpdates,
                   controller.isLayoutBiggerThanVisibleBounds(at: state),
                   let attributes {
                    attributes.frame = attributes.frame.offsetBy(dx: 0, dy: attributes.frame.height * 0.2)
                }
                attributes.map { attributes in
                    guard let delegate else {
                        attributes.alpha = 0
                        return
                    }
                    delegate.finalLayoutAttributesForDeletedItem(self,
                                                                 of: .cell,
                                                                 at: itemIndexPath,
                                                                 modifying: attributes)
                }
            } else if let itemIdentifier = controller.itemIdentifier(for: itemPath, kind: .cell, at: .beforeUpdate),
                      let finalIndexPath = controller.itemPath(by: itemIdentifier, kind: .cell, at: .afterUpdate) {
                if controller.movedIndexes.contains(itemIndexPath)
                    || controller.movedSectionsIndexes.contains(itemPath.section)
                    || controller.reloadedIndexes.contains(itemIndexPath)
                    || controller.reconfiguredIndexes.contains(itemIndexPath)
                    || controller.reloadedSectionsIndexes.contains(itemPath.section) {
                    attributes = controller.itemAttributes(for: finalIndexPath, kind: .cell, at: .afterUpdate)?
                        .typedCopy()
                } else {
                    attributes = controller.itemAttributes(for: itemPath, kind: .cell, at: .beforeUpdate)?.typedCopy()
                }
                if invalidatedAttributes[.cell]?.contains(itemPath) ?? false {
                    attributes = nil
                }

                attributes?.indexPath = itemIndexPath
                attributesForPendingAnimations[.cell]?[itemPath] = attributes
                if
                    controller.reloadedIndexes.contains(itemIndexPath)
                        || controller.reloadedSectionsIndexes.contains(itemPath.section) {
                    attributes?.alpha = 0
                    attributes?.transform = CGAffineTransform(scaleX: 0, y: 0)
                }
            } else {
                attributes = controller.itemAttributes(for: itemPath, kind: .cell, at: .beforeUpdate)
            }
        } else {
            attributes = controller.itemAttributes(for: itemPath, kind: .cell, at: .beforeUpdate)
        }

        return attributes
    }

    // MARK: - Supplementary View Appearance Animation

    open override func initialLayoutAttributesForAppearingSupplementaryElement(
        ofKind elementKind: String,
        at elementIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        var attributes: MessagesLayoutAttributes?

        guard let kind = ItemKind(elementKind) else {
            return nil
        }

        let elementPath = elementIndexPath.itemPath
        if state == .afterUpdate {
            if controller.insertedSectionsIndexes.contains(elementPath.section) {
                attributes = controller.itemAttributes(for: elementPath, kind: kind, at: .afterUpdate)?.typedCopy()
                controller.offsetByTotalCompensation(attributes: attributes, for: state, backward: true)
                attributes.map { attributes in
                    guard let delegate else {
                        attributes.alpha = 0
                        return
                    }
                    delegate.initialLayoutAttributesForInsertedItem(self,
                                                                    of: kind,
                                                                    at: elementIndexPath,
                                                                    modifying: attributes,
                                                                    on: .initial)
                }
                attributesForPendingAnimations[kind]?[elementPath] = attributes
            } else if let itemIdentifier = controller.itemIdentifier(for: elementPath, kind: kind, at: .afterUpdate),
                      let initialIndexPath = controller.itemPath(by: itemIdentifier, kind: kind, at: .beforeUpdate) {
                attributes = controller.itemAttributes(
                    for: initialIndexPath, kind: kind, at: .beforeUpdate)?
                    .typedCopy() ?? MessagesLayoutAttributes(forSupplementaryViewOfKind: elementKind,
                                                             with: elementIndexPath)
                attributes?.indexPath = elementIndexPath
            } else {
                attributes = controller.itemAttributes(for: elementPath, kind: kind, at: .beforeUpdate)
            }
        } else {
            attributes = controller.itemAttributes(for: elementPath, kind: kind, at: .beforeUpdate)
        }

        return attributes
    }

    open override func finalLayoutAttributesForDisappearingSupplementaryElement(
        ofKind elementKind: String,
        at elementIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        var attributes: MessagesLayoutAttributes?

        guard let kind = ItemKind(elementKind) else {
            return nil
        }

        let elementPath = elementIndexPath.itemPath
        if state == .afterUpdate {
            if controller.deletedSectionsIndexes.contains(elementPath.section) {
                attributes = controller.itemAttributes(for: elementPath,
                                                       kind: kind,
                                                       at: .beforeUpdate)?
                    .typedCopy() ?? MessagesLayoutAttributes(forSupplementaryViewOfKind: elementKind,
                                                             with: elementIndexPath)
                controller.offsetByTotalCompensation(attributes: attributes, for: state, backward: false)
                if keepContentOffsetAtBottomOnBatchUpdates,
                   controller.isLayoutBiggerThanVisibleBounds(at: state),
                   let attributes {
                    attributes.frame = attributes.frame.offsetBy(dx: 0, dy: attributes.frame.height * 0.2)
                }
                attributes.map { attributes in
                    guard let delegate else {
                        attributes.alpha = 0
                        return
                    }
                    delegate.finalLayoutAttributesForDeletedItem(self,
                                                                 of: .cell,
                                                                 at: elementIndexPath,
                                                                 modifying: attributes)
                }
            } else if let itemIdentifier = controller.itemIdentifier(for: elementPath, kind: kind, at: .beforeUpdate),
                      let finalIndexPath = controller.itemPath(by: itemIdentifier, kind: kind, at: .afterUpdate) {
                if controller.movedSectionsIndexes.contains(elementPath.section)
                    || controller.reloadedSectionsIndexes.contains(elementPath.section) {
                    attributes = controller.itemAttributes(
                        for: finalIndexPath, kind: kind, at: .afterUpdate
                    )?.typedCopy()
                } else {
                    attributes = controller.itemAttributes(for: elementPath, kind: kind, at: .beforeUpdate)?.typedCopy()
                }
                if invalidatedAttributes[kind]?.contains(elementPath) ?? false {
                    attributes = nil
                }

                attributes?.indexPath = elementIndexPath
                attributesForPendingAnimations[kind]?[elementPath] = attributes
                if controller.reloadedSectionsIndexes.contains(elementPath.section) {
                    attributes?.alpha = 0
                    attributes?.transform = CGAffineTransform(scaleX: 0, y: 0)
                }
            } else {
                attributes = controller.itemAttributes(for: elementPath, kind: kind, at: .beforeUpdate)
            }
        } else {
            attributes = controller.itemAttributes(for: elementPath, kind: kind, at: .beforeUpdate)
        }
        return attributes
    }
}

extension MessagesCollectionLayout {
    func configuration(for element: ItemKind, at indexPath: IndexPath) -> ItemModel.Configuration {
        let itemSize = estimatedSize(for: element, at: indexPath)
        let interItemSpacing: CGFloat
        if element == .cell {
            interItemSpacing = self.interItemSpacing(for: element, at: indexPath)
        } else {
            interItemSpacing = 0
        }
        return ItemModel.Configuration(alignment: alignment(for: element, at: indexPath),
                                       preferredSize: itemSize.estimated,
                                       calculatedSize: itemSize.exact,
                                       interItemSpacing: interItemSpacing)
    }

    private func estimatedSize(for element: ItemKind, at indexPath: IndexPath) -> (estimated: CGSize, exact: CGSize?) {
        guard let delegate else {
            return (estimated: estimatedItemSize, exact: nil)
        }

        let itemSize = delegate.sizeForItem(self, of: element, at: indexPath)

        switch itemSize {
        case .auto:
            return (estimated: estimatedItemSize, exact: nil)
        case let .estimated(size):
            return (estimated: size, exact: nil)
        case let .exact(size):
            return (estimated: size, exact: size)
        }
    }

    private func itemSize(with preferredAttributes: MessagesLayoutAttributes) -> CGSize {
        let itemSize: CGSize
        if let delegate,
           case let .exact(size) = delegate.sizeForItem(self,
                                                        of: preferredAttributes.kind,
                                                        at: preferredAttributes.indexPath) {
            itemSize = size
        } else {
            itemSize = preferredAttributes.size
        }
        return itemSize
    }

    private func interItemSpacing(for kind: ItemKind, at indexPath: IndexPath) -> CGFloat {
        let interItemSpacing: CGFloat
        if let delegate,
           let customInterItemSpacing = delegate.interItemSpacing(self, of: kind, after: indexPath) {
            interItemSpacing = customInterItemSpacing
        } else {
            interItemSpacing = settings.interItemSpacing
        }
        return interItemSpacing
    }

    private func alignment(for element: ItemKind, at indexPath: IndexPath) -> MessagesListItemAlignment {
        guard let delegate else {
            return .fullWidth
        }
        return delegate.alignmentForItem(self, of: element, at: indexPath)
    }

    private var estimatedItemSize: CGSize {
        guard let estimatedItemSize = settings.estimatedItemSize else {
            guard collectionView != nil else {
                return .zero
            }
            return CGSize(width: layoutFrame.width, height: 40)
        }

        return estimatedItemSize
    }

    private func resetAttributesForPendingAnimations() {
        for kind in ItemKind.allCases {
            attributesForPendingAnimations[kind] = [:]
        }
    }

    private func resetInvalidatedAttributes() {
        for kind in ItemKind.allCases {
            invalidatedAttributes[kind] = []
        }
    }
}

extension MessagesCollectionLayout: @preconcurrency MessagesLayoutProtocol {
    func numberOfItems(in section: Int) -> Int {
        guard let collectionView else {
            return .zero
        }
        return collectionView.numberOfItems(inSection: section)
    }

    func shouldPresentHeader(at sectionIndex: Int) -> Bool {
        delegate?.shouldPresentHeader(self, at: sectionIndex) ?? false
    }

    func shouldPresentFooter(at sectionIndex: Int) -> Bool {
        delegate?.shouldPresentFooter(self, at: sectionIndex) ?? false
    }

    func interSectionSpacing(at sectionIndex: Int) -> CGFloat {
        let interItemSpacing: CGFloat
        if let delegate,
           let customInterItemSpacing = delegate.interSectionSpacing(self, after: sectionIndex) {
            interItemSpacing = customInterItemSpacing
        } else {
            interItemSpacing = settings.interSectionSpacing
        }
        return interItemSpacing
    }
}

extension MessagesCollectionLayout {
    private var maxPossibleContentOffset: CGPoint {
        guard let collectionView else {
            return .zero
        }
        let maxContentOffset = max(
            0 - collectionView.adjustedContentInset.top,
            controller.contentHeight(at: state) - collectionView.frame.height
            + collectionView.adjustedContentInset.bottom
        )
        return CGPoint(x: 0, y: maxContentOffset)
    }

    private var isUserInitiatedScrolling: Bool {
        guard let collectionView else {
            return false
        }
        return collectionView.isDragging || collectionView.isDecelerating
    }
}

// swiftlint:enable force_cast force_unwrapping type_body_length no_assertions
