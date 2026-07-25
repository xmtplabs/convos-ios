#if canImport(UIKit)
import Foundation
import UIKit

struct MessagesLayoutSettings: Equatable {
    var estimatedItemSize: CGSize?
    var interItemSpacing: CGFloat = 0
    var interSectionSpacing: CGFloat = 0
    var additionalInsets: UIEdgeInsets = .zero
}
#endif
