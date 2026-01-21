import Foundation
import UIKit

enum ItemKind: CaseIterable, Hashable {
    case header, cell, footer

    init?(_ elementKind: String) {
        switch elementKind {
        case UICollectionView.elementKindSectionHeader:
            self = .header
        case UICollectionView.elementKindSectionFooter:
            self = .footer
        default:
            return nil
        }
    }

    var isSupplementaryItem: Bool {
        switch self {
        case .cell:
            false
        case .footer, .header:
            true
        }
    }

    @MainActor
    var supplementaryElementStringType: String? {
        switch self {
        case .cell:
            nil
        case .header:
            UICollectionView.elementKindSectionHeader
        case .footer:
            UICollectionView.elementKindSectionFooter
        }
    }
}
