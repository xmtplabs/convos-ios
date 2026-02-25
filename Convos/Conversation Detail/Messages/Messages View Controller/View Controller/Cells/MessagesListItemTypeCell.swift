import ConvosCore
import SwiftUI
import UIKit

class MessagesListItemTypeCell: UICollectionViewCell {
    // MARK: - Debug Mode
    // Set to true to show debug borders and height labels
    static let debugMode: Bool = false

    private let debugHeightLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .systemRed
        label.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.8)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupDebugViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDebugViews()
    }

    private func setupDebugViews() {
        guard Self.debugMode else { return }
        contentView.addSubview(debugHeightLabel)
        NSLayoutConstraint.activate([
            debugHeightLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            debugHeightLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            debugHeightLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])
        contentView.layer.borderColor = UIColor.systemBlue.cgColor
        contentView.layer.borderWidth = 2
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.contentConfiguration = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if Self.debugMode {
            debugHeightLabel.text = "H:\(Int(bounds.height))"
            debugHeightLabel.superview?.bringSubviewToFront(debugHeightLabel)
        }
    }

    func setup(item: MessagesListItemType, config: CellConfig) {
        contentConfiguration = UIHostingConfiguration {
            Group {
                switch item {
                case .date(let dateGroup):
                    TextTitleContentView(title: dateGroup.value, profile: nil)
                        .id(dateGroup.differenceIdentifier)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .update(_, let update, _):
                    TextTitleContentView(title: update.summary, profile: update.profile)
                        .id(update.differenceIdentifier)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .messages(let group):
                    MessagesGroupView(
                        group: group,
                        shouldBlurPhotos: config.shouldBlurPhotos,
                        onTapAvatar: config.onTapAvatar,
                        onTapInvite: config.onTapInvite,
                        onTapReactions: config.onTapReactions,
                        onReply: config.onReply,
                        onPhotoRevealed: config.onPhotoRevealed,
                        onPhotoHidden: config.onPhotoHidden,
                        onPhotoDimensionsLoaded: config.onPhotoDimensionsLoaded
                    )

                case .invite(let invite):
                    InviteView(invite: invite)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)

                case .conversationInfo(let conversation):
                    ConversationInfoPreview(conversation: conversation)
                        .padding(.vertical, DesignConstants.Spacing.step4x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                }
            }
            .frame(maxWidth: .infinity, alignment: item.alignment == .center ? .center : .leading)
            .id("message-cell-\(item.differenceIdentifier)")
            .environment(\.messageContextMenuState, config.contextMenuState)
        }
        .margins(.horizontal, 0.0)
        .margins(.vertical, 0.0)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributesForHorizontalFittingRequired(layoutAttributes)
    }
}
