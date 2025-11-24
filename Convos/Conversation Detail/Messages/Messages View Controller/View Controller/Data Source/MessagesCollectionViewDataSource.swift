import Foundation
import SwiftUI
import UIKit

final class MessagesCollectionViewDataSource: NSObject {
    var sections: [MessagesCollectionSection] = [] {
        didSet {
            layoutDelegate = DefaultMessagesLayoutDelegate(sections: sections,
                                                           oldSections: layoutDelegate.sections)
        }
    }

    var onTapAvatar: ((IndexPath) -> Void)?

    private lazy var layoutDelegate: DefaultMessagesLayoutDelegate = DefaultMessagesLayoutDelegate(sections: sections,
                                                                                                   oldSections: [])

    private func registerCells(in collectionView: UICollectionView) {
        collectionView.register(MessagesListItemTypeCell.self,
                                forCellWithReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier)

        collectionView.register(TypingIndicatorCollectionCell.self,
                                forCellWithReuseIdentifier: TypingIndicatorCollectionCell.reuseIdentifier)
    }
}

extension MessagesCollectionViewDataSource: MessagesCollectionDataSource {
    func prepare(with collectionView: UICollectionView) {
        registerCells(in: collectionView)
    }
}

extension MessagesCollectionViewDataSource: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].cells.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = sections[indexPath.section].cells[indexPath.item]
        return CellFactory.createCell(in: collectionView, for: indexPath, with: item) { [weak self] in
            self?.onTapAvatar?(indexPath)
        }
    }
}

extension MessagesCollectionViewDataSource: MessagesLayoutDelegate {
    func shouldPresentHeader(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool {
        layoutDelegate.shouldPresentHeader(messagesLayout, at: sectionIndex)
    }

    func shouldPresentFooter(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool {
        layoutDelegate.shouldPresentFooter(messagesLayout, at: sectionIndex)
    }

    func sizeForItem(_ messagesLayout: MessagesCollectionLayout,
                     of kind: ItemKind,
                     at indexPath: IndexPath) -> ItemSize {
        layoutDelegate.sizeForItem(messagesLayout, of: kind, at: indexPath)
    }

    func alignmentForItem(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          at indexPath: IndexPath) -> MessagesListItemAlignment {
        layoutDelegate.alignmentForItem(messagesLayout, of: kind, at: indexPath)
    }

    func initialLayoutAttributesForInsertedItem(_ messagesLayout: MessagesCollectionLayout,
                                                of kind: ItemKind,
                                                at indexPath: IndexPath,
                                                modifying originalAttributes: MessagesLayoutAttributes,
                                                on state: InitialAttributesRequestType) {
        layoutDelegate.initialLayoutAttributesForInsertedItem(messagesLayout,
                                                              of: kind,
                                                              at: indexPath,
                                                              modifying: originalAttributes,
                                                              on: state)
    }

    func finalLayoutAttributesForDeletedItem(_ messagesLayout: MessagesCollectionLayout,
                                             of kind: ItemKind,
                                             at indexPath: IndexPath,
                                             modifying originalAttributes: MessagesLayoutAttributes) {
        layoutDelegate.finalLayoutAttributesForDeletedItem(messagesLayout,
                                                           of: kind,
                                                           at: indexPath,
                                                           modifying: originalAttributes)
    }

    func interItemSpacing(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          after indexPath: IndexPath) -> CGFloat? {
        layoutDelegate.interItemSpacing(messagesLayout, of: kind, after: indexPath)
    }

    func interSectionSpacing(_ messagesLayout: MessagesCollectionLayout,
                             after sectionIndex: Int) -> CGFloat? {
        layoutDelegate.interSectionSpacing(messagesLayout, after: sectionIndex)
    }
}
