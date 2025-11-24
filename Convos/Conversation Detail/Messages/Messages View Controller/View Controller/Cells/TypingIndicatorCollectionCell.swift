import SwiftUI
import UIKit

class TypingIndicatorCollectionCell: UICollectionViewCell {
    func prepare(with alignment: MessagesListItemAlignment) {
        contentConfiguration = UIHostingConfiguration {
            HStack {
                TypingIndicatorView(alignment: alignment)
                Spacer()
            }
        }
    }
}
