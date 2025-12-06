import ConvosCore
import SwiftUI
import SwiftUIIntrospect

private class TextFieldDelegate: NSObject, UITextFieldDelegate {
    var action: (() -> Void)?

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        action?()
        return false
    }
}

struct QuickEditView: View {
    let placeholderText: String
    @Binding var text: String
    @Binding var image: UIImage?
    @Binding var isImagePickerPresented: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focused: MessagesViewInputFocus
    let imageSymbolName: String = "photo.fill.on.rectangle.fill"
    let settingsSymbolName: String
    let showsSettingsButton: Bool
    let onSubmit: () -> Void
    let onSettings: () -> Void

    @State private var textFieldDelegate: TextFieldDelegate = .init()

    var body: some View {
        HStack {
            ImagePickerButton(
                currentImage: $image,
                isPickerPresented: $isImagePickerPresented,
                symbolName: imageSymbolName
            )
            .frame(width: 52.0, height: 52.0)

            TextField(
                placeholderText,
                text: $text
            )
            .focused($focusState, equals: focused)
            .introspect(.textField, on: .iOS(.v26)) { textField in
                textFieldDelegate.action = onSubmit
                textField.delegate = textFieldDelegate
            }
            .padding(.leading, DesignConstants.Spacing.step4x)
            .font(.body)
            .tint(.colorTextPrimary)
            .foregroundStyle(.colorTextPrimary)
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .submitLabel(.done)
            .frame(minWidth: 166.0)
            .frame(height: 52.0)
            .safeAreaInset(edge: .trailing) {
                if showsSettingsButton {
                    Button {
                        onSettings()
                    } label: {
                        Image(systemName: settingsSymbolName)
                            .resizable()
                            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.colorTextTertiary)
                            .padding(.vertical, 6.0)
                            .padding(.horizontal, 5.0)
                    }
                    .frame(width: 32.0, height: 32.0)
                    .padding(.trailing, 10.0)
                }
            }
            .onChange(of: text) { _, newValue in
                if newValue.count > NameLimits.maxDisplayNameLength {
                    text = String(newValue.prefix(NameLimits.maxDisplayNameLength))
                }
            }
            .background(
                Capsule()
                    .stroke(.colorBorderSubtle, lineWidth: 1.0)
            )

            Button {
                onSubmit()
            } label: {
                Image(systemName: "checkmark")
                    .resizable()
                    .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .padding(DesignConstants.Spacing.step4x)
            }
            .frame(width: 52.0, height: 52.0)
            .background(Circle().fill(.colorFillPrimary))
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    @Previewable @State var text: String = ""
    @Previewable @State var image: UIImage?
    @Previewable @State var isImagePickerPresented: Bool = false
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    QuickEditView(
        placeholderText: "New convo",
        text: $text,
        image: $image,
        isImagePickerPresented: $isImagePickerPresented,
        focusState: $focusState,
        focused: .displayName,
        settingsSymbolName: "gear",
        showsSettingsButton: true,
        onSubmit: {},
        onSettings: {}
    )
}
