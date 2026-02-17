import SwiftUI

struct MessagesMediaInputView: View {
    @Binding var isPhotoPickerPresented: Bool

    private let buttonSize: CGFloat = 32.0

    var body: some View {
        Button {
            isPhotoPickerPresented = true
        } label: {
            Image(systemName: "photo.fill")
                .font(.system(size: 18.0, weight: .medium))
                .foregroundStyle(Color.colorTextSecondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo library")
        .accessibilityIdentifier("photo-picker-button")
    }
}

#Preview {
    @Previewable @State var isPhotoPickerPresented: Bool = false

    VStack(spacing: 20) {
        MessagesMediaInputView(isPhotoPickerPresented: $isPhotoPickerPresented)

        Text(isPhotoPickerPresented ? "Picker shown" : "Picker hidden")
            .foregroundStyle(.secondary)

        Button("Toggle") {
            isPhotoPickerPresented.toggle()
        }
    }
    .padding()
}
