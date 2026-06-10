#if canImport(UIKit)
import Foundation

/// Shared focus vocabulary for the conversation composer. Moved into the package
/// so both the app's conversation view and the share extension speak the same
/// focus targets.
public enum MessagesViewInputFocus: Hashable, Sendable {
    case message
    case displayName
    case conversationName
    case voiceMemoRecording
    case sideConvoName
    case stuffSearchBar
    case agentBuilder
}
#endif
