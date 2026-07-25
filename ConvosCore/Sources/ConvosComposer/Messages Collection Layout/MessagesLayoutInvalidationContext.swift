#if canImport(UIKit)
import Foundation
import UIKit

final class MessagesLayoutInvalidationContext: UICollectionViewLayoutInvalidationContext {
    var invalidateLayoutMetrics: Bool = true
}
#endif
