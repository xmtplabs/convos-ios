import Foundation

// Module overview -- conversation picker entry points
//
// - `stageDraft`: opened from an agent reply's context menu. The picker
//   stages editable text and routes to the selected convo without publishing.

/// Parameterizes `ConversationPickerView` for the action performed after a
/// conversation is chosen. Mirrors `ContactsPickerMode` so later entry points
/// can extend behavior without duplicating the picker.
enum ConversationPickerMode: Hashable {
    case stageDraft(text: String)

    var title: String {
        switch self {
        case .stageDraft:
            return "Copy to convo"
        }
    }
}
