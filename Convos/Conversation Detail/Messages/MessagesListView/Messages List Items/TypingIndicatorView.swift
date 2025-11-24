import SwiftUI

struct TypingIndicatorView: View {
    let alignment: MessagesListItemAlignment
    var body: some View {
        MessageContainer(style: .tailed,
                         isOutgoing: false) {
            ZStack {
                Text("")
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12.0)
                    .font(.body)
                PulsingCircleView.typingIndicator
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    TypingIndicatorView(alignment: .leading)
}
