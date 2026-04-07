import ConvosCore
import UIKit

@MainActor
struct CellConfig {
    let shouldBlurPhotos: Bool
    let onTapInvite: (MessageInvite) -> Void
    let onTapAvatar: (AnyMessage) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void
    let contextMenuState: MessageContextMenuState
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onAgentOutOfCredits: () -> Void
    let onRetryAssistantJoin: () -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onTapUpdateMember: (ConversationMember) -> Void
    let onOpenFile: ((HydratedAttachment) -> Void)?
    let onRetryMessage: (AnyMessage) -> Void
    let onDeleteMessage: (AnyMessage) -> Void
    let onCopyInviteLink: () -> Void
    let onConvoCode: () -> Void
    let onInviteAssistant: () -> Void
    let onToggleTranscript: (String) -> Void
    let onRetryTranscript: (VoiceMemoTranscriptListItem) -> Void
    let hasAssistant: Bool
    let isAssistantJoinPending: Bool
    let isAssistantEnabled: Bool
}

// swiftlint:disable force_cast

@MainActor
final class CellFactory {
    static func createCell(
        in collectionView: UICollectionView,
        for indexPath: IndexPath,
        with item: MessagesListItemType,
        config: CellConfig
    ) -> UICollectionViewCell {
        if case .typingIndicator(let typers) = item {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TypingIndicatorCollectionCell.reuseIdentifier,
                for: indexPath
            ) as! TypingIndicatorCollectionCell
            cell.prepare(with: typers)
            return cell
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier,
            for: indexPath
        ) as! MessagesListItemTypeCell
        cell.setup(item: item, config: config)
        return cell
    }
}

// swiftlint:enable force_cast
