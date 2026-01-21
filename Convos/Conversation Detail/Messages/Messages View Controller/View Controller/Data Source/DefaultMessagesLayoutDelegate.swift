import ConvosCore
import UIKit

@MainActor
final class DefaultMessagesLayoutDelegate: MessagesLayoutDelegate {
    let sections: [MessagesCollectionSection]
    private let oldSections: [MessagesCollectionSection]

    init(sections: [MessagesCollectionSection], oldSections: [MessagesCollectionSection]) {
        self.sections = sections
        self.oldSections = oldSections
    }

    func shouldPresentHeader(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool {
        true
    }

    func shouldPresentFooter(_ messagesLayout: MessagesCollectionLayout, at sectionIndex: Int) -> Bool {
        true
    }

    func sizeForItem(_ messagesLayout: MessagesCollectionLayout,
                     of kind: ItemKind,
                     at indexPath: IndexPath) -> ItemSize {
        switch kind {
        case .cell:
            let item = sections[indexPath.section].cells[indexPath.item]
            switch item {
            case .invite:
                return .estimated(
                    CGSize(
                        width: messagesLayout.layoutFrame.width,
                        height: 316.0
                    )
                )
            case .conversationInfo:
                return .estimated(CGSize(width: messagesLayout.layoutFrame.width, height: 300.0))
            default:
                return .auto
            }
        case .footer, .header:
            return .exact(.zero)
        }
    }

    func alignmentForItem(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          at indexPath: IndexPath) -> MessagesListItemAlignment {
        switch kind {
        case .header:
            return .center
        case .cell:
            let item = sections[indexPath.section].cells[indexPath.item]
            return item.alignment
        case .footer:
            return .trailing
        }
    }

    func initialLayoutAttributesForInsertedItem(_ messagesLayout: MessagesCollectionLayout,
                                                of kind: ItemKind,
                                                at indexPath: IndexPath,
                                                modifying originalAttributes: MessagesLayoutAttributes,
                                                on state: InitialAttributesRequestType) {
        originalAttributes.alpha = 0
        guard state == .invalidation,
              kind == .cell else {
            return
        }

        let item = sections[indexPath.section].cells[indexPath.item]
        switch item {
        case .messages(let messagesGroup):
            applyMessageAnimation(for: messagesGroup, to: originalAttributes)
        case .date, .update:
            originalAttributes.center.y += 40.0
            originalAttributes.transform = .init(scaleX: 0.1, y: 0.1)
        default:
            break
        }
    }

    func finalLayoutAttributesForDeletedItem(_ messagesLayout: MessagesCollectionLayout,
                                             of kind: ItemKind,
                                             at indexPath: IndexPath,
                                             modifying originalAttributes: MessagesLayoutAttributes) {
        originalAttributes.alpha = 0
        guard kind == .cell else {
            return
        }

        let oldItem = oldSections[indexPath.section].cells[indexPath.item]
        switch oldItem {
        case .messages(let messagesGroup):
            applyMessageAnimation(for: messagesGroup, to: originalAttributes)
        case .date, .update:
            originalAttributes.center.y += 40.0
            originalAttributes.transform = .init(scaleX: 0.1, y: 0.1)
        default:
            break
        }
    }

    func interItemSpacing(_ messagesLayout: MessagesCollectionLayout,
                          of kind: ItemKind,
                          after indexPath: IndexPath) -> CGFloat? {
        return nil
    }

    func interSectionSpacing(_ messagesLayout: MessagesCollectionLayout, after sectionIndex: Int) -> CGFloat? {
        return nil
    }

    // MARK: - Private Helpers

    private func safeCell(at indexPath: IndexPath) -> MessagesListItemType? {
        guard !sections.isEmpty, sections.count > indexPath.section else {
            return nil
        }
        let section = sections[indexPath.section]
        guard !section.cells.isEmpty, section.cells.count > indexPath.item else {
            return nil
        }
        return section.cells[indexPath.item]
    }

    private func applyMessageAnimation(for messages: MessagesGroup, to attributes: MessagesLayoutAttributes) {
        attributes.center.y += 120.0
    }
}

extension IndexPath {
    var nextItem: IndexPath {
        .init(item: item + 1, section: section)
    }
}
