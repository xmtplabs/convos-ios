import Foundation
import UIKit

enum InitialAttributesRequestType: Hashable {
    case initial, invalidation
}

@MainActor
protocol MessagesLayoutDelegate: AnyObject {
    func shouldPresentHeader(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool
    func shouldPresentFooter(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool
    func sizeForItem(_ messagesLayout: MessagesCollectionLayout,
                     of kind: ItemKind,
                     at indexPath: IndexPath) -> ItemSize
    func alignmentForItem(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          at indexPath: IndexPath) -> MessagesListItemAlignment
    func initialLayoutAttributesForInsertedItem(_ messagesLayout: MessagesCollectionLayout,
                                                of kind: ItemKind,
                                                at indexPath: IndexPath,
                                                modifying originalAttributes: MessagesLayoutAttributes,
                                                on state: InitialAttributesRequestType)
    func finalLayoutAttributesForDeletedItem(_ messagesLayout: MessagesCollectionLayout,
                                             of kind: ItemKind,
                                             at indexPath: IndexPath,
                                             modifying originalAttributes: MessagesLayoutAttributes)
    func interItemSpacing(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          after indexPath: IndexPath) -> CGFloat?
    func interSectionSpacing(_ messagesLayout: MessagesCollectionLayout, after sectionIndex: Int) -> CGFloat?
}

extension MessagesLayoutDelegate {
    func shouldPresentHeader(_ messagesLayout: MessagesCollectionLayout,
                             at sectionIndex: Int) -> Bool {
        false
    }

    func shouldPresentFooter(_ messagesLayout: MessagesCollectionLayout,
                             at sectionIndex: Int) -> Bool {
        false
    }

    func sizeForItem(_ messagesLayout: MessagesCollectionLayout,
                     of kind: ItemKind,
                     at indexPath: IndexPath) -> ItemSize {
        .auto
    }

    func alignmentForItem(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          at indexPath: IndexPath) -> MessagesListItemAlignment {
        .fullWidth
    }

    func initialLayoutAttributesForInsertedItem(_ messagesLayout: MessagesCollectionLayout,
                                                of kind: ItemKind,
                                                at indexPath: IndexPath,
                                                modifying originalAttributes: MessagesLayoutAttributes,
                                                on state: InitialAttributesRequestType) {
        originalAttributes.alpha = 0
    }

    func finalLayoutAttributesForDeletedItem(_ messagesLayout: MessagesCollectionLayout,
                                             of kind: ItemKind,
                                             at indexPath: IndexPath,
                                             modifying originalAttributes: MessagesLayoutAttributes) {
        originalAttributes.alpha = 0
    }

    func interItemSpacing(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          after indexPath: IndexPath) -> CGFloat? {
        nil
    }

    func interSectionSpacing(_ messagesLayout: MessagesCollectionLayout,
                             after sectionIndex: Int) -> CGFloat? {
        nil
    }
}
