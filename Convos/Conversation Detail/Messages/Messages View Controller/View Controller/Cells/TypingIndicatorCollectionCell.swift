import ConvosCore
import SwiftUI
import UIKit

class TypingIndicatorCollectionCell: UICollectionViewCell {
    func prepare(with typers: [ConversationMember]) {
        contentConfiguration = UIHostingConfiguration {
            HStack {
                TypingIndicatorView(typers: typers)
                Spacer()
            }
        }
    }
}
