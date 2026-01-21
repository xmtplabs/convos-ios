import Foundation
import UIKit

// swiftlint:disable no_assertions

enum ChangeItem: Equatable {
    case sectionDelete(sectionIndex: Int)
    case itemDelete(itemIndexPath: IndexPath)
    case sectionInsert(sectionIndex: Int)
    case itemInsert(itemIndexPath: IndexPath)
    case sectionReload(sectionIndex: Int)
    case itemReload(itemIndexPath: IndexPath)
    case itemReconfigure(itemIndexPath: IndexPath)
    case sectionMove(initialSectionIndex: Int, finalSectionIndex: Int)
    case itemMove(initialItemIndexPath: IndexPath, finalItemIndexPath: IndexPath)

    @MainActor
    init?(with updateItem: UICollectionViewUpdateItem) {
        let updateAction = updateItem.updateAction
        let indexPathBeforeUpdate = updateItem.indexPathBeforeUpdate
        let indexPathAfterUpdate = updateItem.indexPathAfterUpdate
        switch updateAction {
        case .none:
            return nil
        case .move:
            guard let indexPathBeforeUpdate,
                  let indexPathAfterUpdate else {
                assertionFailure(
                    "`indexPathBeforeUpdate` and `indexPathAfterUpdate` cannot be `nil` for a `.move` update action."
                )
                return nil
            }
            if indexPathBeforeUpdate.item == NSNotFound, indexPathAfterUpdate.item == NSNotFound {
                self = .sectionMove(initialSectionIndex: indexPathBeforeUpdate.section,
                                    finalSectionIndex: indexPathAfterUpdate.section)
            } else {
                self = .itemMove(initialItemIndexPath: indexPathBeforeUpdate,
                                 finalItemIndexPath: indexPathAfterUpdate)
            }
        case .insert:
            guard let indexPath = indexPathAfterUpdate else {
                assertionFailure("`indexPathAfterUpdate` cannot be `nil` for an `.insert` update action.")
                return nil
            }
            if indexPath.item == NSNotFound {
                self = .sectionInsert(sectionIndex: indexPath.section)
            } else {
                self = .itemInsert(itemIndexPath: indexPath)
            }
        case .delete:
            guard let indexPath = indexPathBeforeUpdate else {
                assertionFailure("`indexPathBeforeUpdate` cannot be `nil` for a `.delete` update action.")
                return nil
            }
            if indexPath.item == NSNotFound {
                self = .sectionDelete(sectionIndex: indexPath.section)
            } else {
                self = .itemDelete(itemIndexPath: indexPath)
            }
        case .reload:
            guard let indexPath = indexPathBeforeUpdate else {
                assertionFailure("`indexPathAfterUpdate` cannot be `nil` for a `.reload` update action.")
                return nil
            }

            if indexPath.item == NSNotFound {
                self = .sectionReload(sectionIndex: indexPath.section)
            } else {
                self = .itemReload(itemIndexPath: indexPath)
            }
        @unknown default:
            return nil
        }
    }
}

// swiftlint:enable no_assertions
