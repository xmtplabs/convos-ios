# Context Menu Implementation Attempts

## Goal
Add Reply and Copy actions to message long-press, using the native iOS edit menu style (pill-shaped menu like the screenshot showing "Copy"), where the bubble does not animate during the interaction.

## Existing Systems
1. **SwiftUI Text with `.textSelection(.enabled)`**: Shows native "Copy" menu on long press without animation
2. **Custom UIKit Reaction Menu**: `MessageReactionMenuController` - custom menu with emoji reactions, animated presentation

---

## Attempt 1: SwiftUI `.contextMenu` with Preview

**Approach**: Use SwiftUI's `.contextMenu(menuItems:preview:)` modifier on `MessageBubble`.

```swift
.contextMenu {
    Button { onReply(message) } label: {
        Label("Reply", systemImage: "arrowshape.turn.up.left")
    }
    Button { ... } label: {
        Label("Copy", systemImage: "doc.on.doc")
    }
} preview: {
    MessageBubble(...)
}
```

**Result**: FAILED
- iOS's built-in context menu has a "lift effect" that adds a shadow/contour around the preview
- This shadow cannot be disabled via SwiftUI APIs
- The shadow appears during the long press transition and looks jarring

---

## Attempt 2: Context Menu with Custom Preview Shape

**Approach**: Use `.contentShape(.contextMenuPreview, ...)` to control the preview shape.

```swift
.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
```

**Result**: FAILED
- The shape modifier controls the hit area, not the shadow
- The lift shadow still appears around the entire view

---

## Attempt 3: Context Menu with Fixed-Size Preview

**Approach**: Wrap the preview in a fixed-size container to match bubble dimensions.

```swift
preview: {
    MessageBubble(...)
        .fixedSize()
}
```

**Result**: FAILED
- `MessageContainer` uses HStack with Spacers that have `layoutPriority: -1` and `minWidth: 50`
- These spacers expand to fill available width regardless of `.fixedSize()`
- Preview width doesn't match the original bubble width

---

## Attempt 4: Manual Width Calculation

**Approach**: Calculate the actual bubble width and constrain the preview.

```swift
preview: {
    MessageBubble(...)
        .frame(maxWidth: UIScreen.main.bounds.width * 0.75)
}
```

**Result**: FAILED
- Arbitrary percentage doesn't match actual bubble size
- The spacer issue means the wrapper still expands

---

## Attempt 5: GeometryReader for Width

**Approach**: Use GeometryReader to capture actual bubble width.

**Result**: FAILED
- GeometryReader in preview context doesn't have access to the original view's geometry
- Complex state management needed to pass width between views

---

## Attempt 6: Integrate into Custom UIKit Reaction Menu

**Approach**: Add Reply and Copy buttons to the existing `MessageReactionMenuController`.

**Implementation**:
- Added `replyButton` and `copyButton` UIButton properties
- Added `setupActionButtons()` method with filled button configuration
- Added `animateActionButtonsToEndPosition()` and `animateActionButtonsToStartPosition()`
- Added `handleReplyTap()` and `handleCopyTap()` handlers
- Updated `MessageReactionMenuViewModel` with `canReply`, `onReply`, `copyableText`, `onCopy`

**Result**: Works but different UX
- Reply/Copy buttons appear below the preview after animation completes
- Full reaction menu experience (blur background, preview animation)
- Not the simple native edit menu the user wanted

---

## Attempt 7: UITextView with UITextViewDelegate

**Approach**: Replace SwiftUI Text with UITextView via UIViewRepresentable, use `textView(_:editMenuForTextIn:suggestedActions:)` delegate method.

```swift
func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
    var actions = suggestedActions
    let replyAction = UIAction(title: "Reply", ...) { _ in onReply() }
    actions.insert(replyAction, at: 0)
    return UIMenu(children: actions)
}
```

**Result**: FAILED
- UITextView's edit menu only appears after text selection
- User must select text first, then menu appears
- This is fundamentally different from the SwiftUI `.textSelection(.enabled)` behavior
- Creates selectable text experience, not simple long-press menu

---

## Attempt 8: UIEditMenuInteraction on UITextView

**Approach**: Add `UIEditMenuInteraction` to UITextView subclass.

**Result**: FAILED
- UITextView already has its own text interaction that handles edit menus
- Adding a separate UIEditMenuInteraction conflicts with built-in behavior
- Same text selection issue as Attempt 7

---

## Key Findings

1. **SwiftUI `.textSelection(.enabled)`** on Text provides the exact UX wanted (immediate "Copy" menu on long press, no animation), but SwiftUI provides no API to add custom actions to this menu.

2. **SwiftUI `.contextMenu`** allows custom actions but has an unavoidable lift shadow effect during the transition.

3. **UITextView** requires text selection before showing its edit menu, which is a different UX than SwiftUI Text.

4. **UILabel with UITextInteraction** might provide a closer experience to SwiftUI Text, but wasn't attempted.

5. The **existing custom reaction menu** already handles Reply via swipe gesture and could show buttons, but has a different visual treatment.

---

## Potential Future Approaches

1. **UILabel + UITextInteraction**: May provide immediate edit menu without text selection requirement

2. **Custom UIView with UIEditMenuInteraction**: Build from scratch without UITextView's built-in interactions

3. **Private API exploration**: SwiftUI Text's text selection might use internal APIs that could be replicated

4. **Keep native Copy, add Reply differently**: Accept that Reply cannot be added to the native Copy menu, use swipe-to-reply as the primary reply mechanism

5. **Wait for iOS updates**: Future iOS versions may provide SwiftUI APIs to customize the text selection menu
