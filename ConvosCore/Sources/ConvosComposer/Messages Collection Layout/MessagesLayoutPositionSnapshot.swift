#if canImport(UIKit)
import Foundation
import UIKit

/// Represents content offset position expressed by the specific item and it offset from the top or bottom edge.
struct MessagesLayoutPositionSnapshot: Hashable {
    enum Edge: Hashable {
        case top, bottom
    }

    var indexPath: IndexPath
    var kind: ItemKind
    var edge: Edge
    var offset: CGFloat

    init(indexPath: IndexPath,
         kind: ItemKind,
         edge: Edge,
         offset: CGFloat = 0.0) {
        self.indexPath = indexPath
        self.edge = edge
        self.offset = offset
        self.kind = kind
    }
}
#endif
