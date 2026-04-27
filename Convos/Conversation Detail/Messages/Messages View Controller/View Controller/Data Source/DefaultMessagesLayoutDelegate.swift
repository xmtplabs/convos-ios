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
            case .agentOutOfCredits:
                return .estimated(CGSize(width: width, height: 48.0))
            case .assistantJoinStatus:
                return .estimated(CGSize(width: width, height: 48.0))
            case .assistantPresentInfo:
                return .estimated(CGSize(width: width, height: 48.0))
            case .typingIndicator:
                return .estimated(CGSize(width: width, height: 48.0))
            }
        case .footer, .header:
            return .exact(.zero)
        }
    }

    private func estimatedHeight(for group: MessagesGroup, width: CGFloat) -> CGFloat {
        var height: CGFloat = 16.0
        var childCount: Int = 0

        for (index, message) in group.messages.enumerated() {
            let isFullBleed = message.content.isFullBleedAttachment

            if index == 0 && !group.sender.isCurrentUser && !isFullBleed {
                height += 17.0
                childCount += 1
            }

            height += messageHeight(for: message, width: width)
            childCount += 1

            // Inline voice memo transcript row, when one exists for this message.
            // The transcript cell sits inside the same MessagesGroupItemView VStack
            // directly under the voice memo bubble, so its height is part of the
            // parent message cell's height, not a separate list item. The VStack
            // uses `spacing: 0` so we don't add inter-child spacing, just the row's
            // explicit `.padding(.top, stepX)`.
            if let transcript = group.voiceMemoTranscripts[message.messageId] {
                height += DesignConstants.Spacing.stepX
                height += estimatedTranscriptHeight(for: transcript)
            }

            if !message.reactions.isEmpty {
                height += 34.0
                childCount += 1
            }

            let isLast = index == group.messages.count - 1
            if isLast && group.isLastGroupSentByCurrentUser && message.status == .published {
                height += 24.0
                childCount += 1
            }
        }

        if childCount > 1 {
            height += CGFloat(childCount - 1) * 4.0
        }

        return height
    }

    private func estimatedAttachmentHeight(for attachment: HydratedAttachment, width: CGFloat) -> CGFloat {
        switch attachment.mediaType {
        case .audio:
            // VoiceMemoBubbleContent: 12pt top padding + 36pt play button + 12pt
            // bottom padding = 60pt. Any inline transcript row is added separately
            // in `estimatedHeight(for:width:)` so outgoing voice memos (which never
            // get a transcript) don't reserve space they won't use.
            return 60.0
        case .file:
            return 60.0
        case .image, .video, .unknown:
            return imageAttachmentHeight(for: attachment, width: width)
        }
    }

    /// Estimated rendered height of a `VoiceMemoTranscriptRow` for layout pre-flight.
    /// The numbers here are measured empirically from SwiftUI's actual output so the
    /// initial collection view content size matches the final size closely enough
    /// that there is no visible jump when the cells finish self-sizing.
    private func estimatedTranscriptHeight(for transcript: VoiceMemoTranscriptListItem) -> CGFloat {
        switch transcript.status {
        case .notRequested:
            // Capsule-only row ("Tap to transcribe").
            return 46
        case .failed:
            return 0
        case .pending:
            // Spinner + "Transcribing…" text.
            return 40
        case .completed:
            // Caption2 header + 2-line preview text. Measured at ~56pt on a real
            // device; see `[LayoutHeights] fitting=158.3` logs against the
            // bare voice memo bubble at 97.7pt (delta = 60.6pt which includes the
            // `stepX` top padding added by the parent VStack).
            return 56
        case .permanentlyFailed:
            // `MessagesListRepository.synthesizeTranscriptItems` strips these
            // rows from the map so they are never attached to a `MessagesGroup`,
            // meaning this code path is unreachable in practice. The exhaustive
            // switch still needs a branch for compile-time completeness.
            return 0
        }
    }

    private func imageAttachmentHeight(for attachment: HydratedAttachment, width: CGFloat) -> CGFloat {
        guard let w = attachment.width, let h = attachment.height, w > 0, h > 0 else {
            return width * 0.75
        }
        return width * CGFloat(h) / CGFloat(w)
    }

    private func messageHeight(for message: AnyMessage, width: CGFloat) -> CGFloat {
        var height: CGFloat
        switch message.content {
        case .attachment(let attachment):
            height = estimatedAttachmentHeight(for: attachment, width: width)
        case .attachments(let attachments):
            guard let first = attachments.first else { return 50.0 }
            height = estimatedAttachmentHeight(for: first, width: width)
        case .emoji:
            height = 80.0
        case .text:
            height = 40.0
        case .invite:
            height = 240.0
        case .linkPreview:
            height = 210.0
        case .update, .assistantJoinRequest:
            height = 30.0
        case .connectionGrantRequest:
            height = 160.0
        }

        if case .reply(let reply, _) = message {
            height += 24.0
            switch reply.parentMessage.content {
            case .attachment, .attachments:
                height += 88.0
            case .emoji:
                height += 44.0
            case .invite, .linkPreview:
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
