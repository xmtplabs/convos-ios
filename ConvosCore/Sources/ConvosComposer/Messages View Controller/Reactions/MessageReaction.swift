#if canImport(UIKit)
import Foundation

struct MessageReactionChoice: Identifiable {
    var id: String {
        emoji
    }
    let emoji: String
    let isSelected: Bool
}
#endif
