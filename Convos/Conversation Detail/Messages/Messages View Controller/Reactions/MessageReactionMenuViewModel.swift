import Combine
import Foundation
import SwiftUI

@MainActor
@Observable
class MessageReactionMenuViewModel {
    enum ViewState {
        case minimized, // scale 0
             collapsed, // smallest
             compact,
             expanded // largest

        var isCollapsed: Bool {
            self == .collapsed
        }

        var isMinimized: Bool {
            self == .minimized
        }

        var hidesContent: Bool {
            switch self {
            case .minimized, .compact, .collapsed:
                return true
            case .expanded:
                return false
            }
        }

        var isCompact: Bool {
            self == .compact
        }

        var isExpanded: Bool {
            self == .expanded
        }
    }

    var canReply: Bool = false
    var onReply: (() -> Void)?

    var copyableText: String?
    var onCopy: (() -> Void)?

    var alignment: Alignment = .leading

    var viewState: ViewState = .minimized {
        didSet {
            showingEmojiPicker = viewState == .compact && selectedEmoji == nil
        }
    }

    var showingEmojiPicker: Bool = false

    var selectedEmoji: String? {
        didSet {
            viewState = .collapsed
            if showingEmojiPicker {
                showingEmojiPicker = false
            }
            _selectedEmojiPublisher.send(selectedEmoji)
        }
    }

    private let _selectedEmojiPublisher: PassthroughSubject<String?, Never> = .init()
    var selectedEmojiPublisher: AnyPublisher<String?, Never> {
        _selectedEmojiPublisher.eraseToAnyPublisher()
    }

    var reactions: [MessageReactionChoice] = [
        .init(emoji: "❤️", isSelected: false),
        .init(emoji: "👍", isSelected: false),
        .init(emoji: "👎", isSelected: false),
        .init(emoji: "😂", isSelected: false),
        .init(emoji: "😮", isSelected: false),
        .init(emoji: "🤔", isSelected: false),
    ]

    func add(reaction: MessageReactionChoice) {
        selectedEmoji = reaction.emoji
    }
}
