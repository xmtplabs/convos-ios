#if canImport(UIKit)
import Foundation
import UIKit

extension IndexPath {
    var itemPath: ItemPath {
        ItemPath(for: self)
    }
}

/// lightweight version of IndexPath
struct ItemPath: Hashable {
    let section: Int

    let item: Int

    var indexPath: IndexPath {
        IndexPath(item: item, section: section)
    }

    init(item: Int, section: Int) {
        self.section = section
        self.item = item
    }

    init(for indexPath: IndexPath) {
        section = indexPath.section
        item = indexPath.item
    }
}
#endif
