import ConvosCore
import SwiftUI

struct QuickEditView: View {
    let placeholderText: String
    @Binding var text: String
    @Binding var image: UIImage?
    @Binding var isImagePickerPresented: Bool
    var imageAssetIdentifier: Binding<String?>?
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focused: MessagesViewInputFocus
    let imageSymbolName: String = "photo.fill.on.rectangle.fill"
    let settingsSymbolName: String
    let showsSettingsButton: Bool
    let onSubmit: () -> Void
    let onSettings: () -> Void

    @ViewBuilder
    private var settingsButton: some View {
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
            .accessibilityLabel("Profile settings")
            .accessibilityIdentifier("quick-edit-settings-button")
        }
    }

    private var doneButton: some View {
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
        .accessibilityLabel("Done editing")
        .accessibilityIdentifier("quick-edit-done-button")
    }

    private func handleReturn() {
        onSubmit()
        Task { @MainActor in
            focusState = focused
        }
    }

    private var styledNameField: some View {
        let leadingPadding: CGFloat = DesignConstants.Spacing.step4x
        return TextField(placeholderText, text: $text)
            .focused($focusState, equals: focused)
            .onSubmit(handleReturn)
            .padding(.leading, leadingPadding)
            .font(.body)
            .tint(.colorTextPrimary)
            .foregroundStyle(.colorTextPrimary)
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .submitLabel(.done)
    }

    private var nameTextField: some View {
        let fieldHeight: CGFloat = 52.0
        let borderColor: Color = .colorBorderSubtle
        return styledNameField
            .frame(height: fieldHeight)
            .accessibilityIdentifier("quick-edit-display-name-field")
            .safeAreaInset(edge: .trailing) { settingsButton }
            .onChange(of: text) { _, newValue in
                let maxLength: Int = NameLimits.maxDisplayNameLength
                if newValue.count > maxLength {
                    text = String(newValue.prefix(maxLength))
                }
            }
            .background(Capsule().stroke(borderColor, lineWidth: 1.0))
    }

    var body: some View {
        HStack {
            ImagePickerButton(
                currentImage: $image,
                isPickerPresented: $isImagePickerPresented,
                currentImageAssetIdentifier: imageAssetIdentifier,
                symbolName: imageSymbolName
            )
            .frame(width: 52.0, height: 52.0)
            .accessibilityIdentifier("quick-edit-image-picker")

            nameTextField

            doneButton
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
