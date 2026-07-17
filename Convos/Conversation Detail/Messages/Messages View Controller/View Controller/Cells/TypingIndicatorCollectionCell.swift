import ConvosCore
import SwiftUI
import UIKit

class TypingIndicatorCollectionCell: UICollectionViewCell {
    func prepare(with typers: [ConversationMember]) {
        // `prepare(with:)` runs on every dequeue, reassigning a same-typed
        // `UIHostingConfiguration` that UIKit applies in place. The `.id` keyed
        // on the typer set gives the content a fresh SwiftUI identity when a
        // recycled cell is reused for a different set of typers, so transient
        // state doesn't carry over - matching the `.id` on the message cells.
        let typersIdentity: String = typers.map(\.profile.inboxId).joined(separator: ",")
        contentConfiguration = UIHostingConfiguration {
            HStack {
                TypingIndicatorView(typers: typers)
                Spacer()
            }
            .id("typing-indicator-cell-\(typersIdentity)")
        }
    }
}
