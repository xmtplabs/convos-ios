import SwiftUI

struct MessagesMediaInputView: View {
    @Binding var messageText: String
    @FocusState.Binding var focusState: MessagesViewInputFocus?

    @State private var isExpanded: Bool = true

    static var defaultHeight: CGFloat {
        32.0
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step4x) {
            if isExpanded {
                Button {
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22.0))
                        .foregroundStyle(.colorTextSecondary)
                }

                Button {
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22.0))
                        .foregroundStyle(.colorTextSecondary)
                }

                Button {
                } label: {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 22.0))
                        .foregroundStyle(.colorTextSecondary)
                }
            } else {
                Button {
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 22.0))
                        .foregroundStyle(.colorTextSecondary)
                }
            }
        }
        .frame(height: Self.defaultHeight)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }
}

#Preview {
    @Previewable @State var messageText: String = ""
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    MessagesMediaInputView(messageText: $messageText, focusState: $focusState)
}
