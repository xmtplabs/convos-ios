import SwiftUI

struct LabeledTextField: View {
    let label: String
    let prompt: String
    let textFieldBorderColor: Color
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        LabeledContent {
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(.colorTextTertiary))
                .foregroundStyle(Color.colorTextPrimary)
                .font(DesignConstants.Fonts.medium)
                .focused($isFocused)
        } label: {
            Text(label)
                .foregroundStyle(.colorTextPrimary)
                .font(DesignConstants.Fonts.small)
        }
        .labeledContentStyle(.vertical)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
                .inset(by: 0.5)
                .stroke(textFieldBorderColor, lineWidth: 1.0)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

#Preview {
    @Previewable @FocusState var isFocused: Bool
    LabeledTextField(label: "Name",
                     prompt: "Nice to meet you",
                     textFieldBorderColor: .colorBorderSubtle,
                     text: .constant(""),
                     isFocused: $isFocused)
}
