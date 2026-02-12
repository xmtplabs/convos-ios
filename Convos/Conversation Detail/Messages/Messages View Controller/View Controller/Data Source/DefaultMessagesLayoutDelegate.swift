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
            let width = messagesLayout.layoutFrame.width
            switch item {
            case .invite:
                return .estimated(CGSize(width: width, height: 348.0))
            case .conversationInfo:
                return .estimated(CGSize(width: width, height: 300.0))
            case .date:
                return .estimated(CGSize(width: width, height: 48.0))
            case .update:
                return .estimated(CGSize(width: width, height: 48.0))
            case .messages(let group):
                return .estimated(CGSize(width: width, height: estimatedHeight(for: group, width: width)))
            }
        case .footer, .header:
            return .exact(.zero)
        }
    }

    private func estimatedHeight(for group: MessagesGroup, width: CGFloat) -> CGFloat {
        var height: CGFloat = 16.0
        var childCount: Int = 0

        for (index, message) in group.messages.enumerated() {
            let isAttachment = message.base.content.isAttachment

            if index == 0 && !group.sender.isCurrentUser && !isAttachment {
                height += 17.0
                childCount += 1
            }

            height += messageHeight(for: message, width: width)
            childCount += 1

            if !message.base.reactions.isEmpty {
                height += 34.0
                childCount += 1
            }

            let isLast = index == group.messages.count - 1
            if isLast && group.isLastGroupSentByCurrentUser && message.base.status == .published {
                height += 24.0
                childCount += 1
            }
        }

        if childCount > 1 {
            height += CGFloat(childCount - 1) * 4.0
        }

        return height
    }

    private func attachmentHeight(for attachment: HydratedAttachment, width: CGFloat) -> CGFloat {
        guard let w = attachment.width, let h = attachment.height, w > 0, h > 0 else {
            return width * 0.75
        }
        return width * CGFloat(h) / CGFloat(w)
    }

    private func messageHeight(for message: AnyMessage, width: CGFloat) -> CGFloat {
        var height: CGFloat
        switch message.base.content {
        case .attachment(let attachment):
            height = attachmentHeight(for: attachment, width: width)
        case .attachments(let attachments):
            guard let first = attachments.first else { return 50.0 }
            height = attachmentHeight(for: first, width: width)
        case .emoji:
            height = 80.0
        case .text:
            height = 40.0
        case .invite:
            height = 240.0
        case .update:
            height = 30.0
        }

        if case .reply(let reply, _) = message {
            height += 24.0
            switch reply.parentMessage.content {
            case .attachment, .attachments:
                height += 88.0
            case .emoji:
                height += 44.0
            case .invite:
                height += 176.0
            default:
                height += 32.0
            }
        }

        return height
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
