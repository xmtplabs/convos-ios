#if canImport(UIKit)
import SwiftUI

/// https://gist.github.com/darrarski/ce912bef767c6b93582b63b12f946c31
struct EmojiPickerView: UIViewRepresentable {
    @Binding var isFirstResponder: Bool
    var onPick: (String) -> Void
    var onDelete: () -> Void

    func makeUIView(context: Context) -> UIViewType {
        UIViewType(view: self)
    }

    func updateUIView(_ uiView: UIViewType, context: Context) {
        DispatchQueue.main.async {
            uiView.view = self
        }
    }

    class UIViewType: UIView, UIKeyInput {
        init(view: EmojiPickerView) {
            self.view = view
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        var view: EmojiPickerView {
            didSet {
                if view.isFirstResponder && !isFirstResponder {
                    _ = becomeFirstResponder()
                }
                if !view.isFirstResponder && isFirstResponder {
                    _ = resignFirstResponder()
                }
            }
        }

        var hasText: Bool = true
        override var canBecomeFirstResponder: Bool { true }
        override var canResignFirstResponder: Bool { true }
        override var textInputContextIdentifier: String? { "" }
        override var textInputMode: UITextInputMode? { .emoji }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result && !view.isFirstResponder {
                view.isFirstResponder = true
            }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result && view.isFirstResponder {
                view.isFirstResponder = false
            }
            return result
        }

        func insertText(_ text: String) {
            if text.containsOnlyEmoji {
                view.onPick(text)
            } else {
                _ = resignFirstResponder()
            }
        }

        func deleteBackward() {
            view.onDelete()
        }
    }
}

extension UITextInputMode {
    static var emoji: UITextInputMode? {
        .activeInputModes.first { $0.primaryLanguage == "emoji" }
    }
}

extension Character {
    var isSimpleEmoji: Bool {
        guard let firstScalar = unicodeScalars.first else { return false }
        return firstScalar.properties.isEmoji && firstScalar.value > 0x238C
    }

    var isCombinedIntoEmoji: Bool {
        unicodeScalars.count > 1 && unicodeScalars.first?.properties.isEmoji ?? false
    }

    var isEmoji: Bool {
        isSimpleEmoji || isCombinedIntoEmoji
    }
}

extension String {
    var containsOnlyEmoji: Bool {
        !isEmpty && allSatisfy(\.isEmoji)
    }
}

struct EmojiPickerViewModifier: ViewModifier {
    @Binding var isPresented: Bool
    var onPick: (String) -> Void
    var onDelete: () -> Void

    func body(content: Content) -> some View {
        content.background {
            EmojiPickerView(
                isFirstResponder: $isPresented,
                onPick: onPick,
                onDelete: onDelete
            )
        }
    }
}

extension View {
    public func emojiPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (String) -> Void,
        onDelete: @escaping () -> Void = {}
    ) -> some View {
        modifier(EmojiPickerViewModifier(
            isPresented: isPresented,
            onPick: onPick,
            onDelete: onDelete
        ))
    }
}
#endif
