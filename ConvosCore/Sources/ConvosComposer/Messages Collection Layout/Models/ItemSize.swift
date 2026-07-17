#if canImport(UIKit)
import Foundation
import UIKit

enum ItemSize: Hashable {
    case auto, estimated(CGSize), exact(CGSize)

    enum CaseType: Hashable, CaseIterable {
        case auto, estimated, exact
    }

    var caseType: CaseType {
        switch self {
        case .auto:
            .auto
        case .estimated:
            .estimated
        case .exact:
            .exact
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(caseType)
        switch self {
        case .auto:
            break
        case let .estimated(size):
            hasher.combine(size.width)
            hasher.combine(size.height)
        case let .exact(size):
            hasher.combine(size.width)
            hasher.combine(size.height)
        }
    }
}
#endif
