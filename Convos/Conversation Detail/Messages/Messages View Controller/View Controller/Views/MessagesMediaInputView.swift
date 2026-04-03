import SwiftUI

struct MessagesMediaButtonsView: View {
    @Binding var isPhotoPickerPresented: Bool
    @Binding var isCameraPresented: Bool
    let onConvosAction: () -> Void

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Image(systemName: "photo.fill")
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(Color.colorTextSecondary)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo library")
            .accessibilityIdentifier("photo-picker-button")

            Button {
                isCameraPresented = true
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(Color.colorTextSecondary)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera")
            .accessibilityIdentifier("camera-button")

            // Convos action button (hidden until feature is ready)
            // Button {
            //     onConvosAction()
            // } label: {
            //     Image("convosOrangeIcon")
            //         .renderingMode(.template)
            //         .resizable()
            //         .scaledToFit()
            //         .frame(height: 18)
            //         .foregroundStyle(Color.colorTextSecondary)
            //         .frame(width: Constant.buttonSize, height: Constant.buttonSize)
            //         .contentShape(.circle)
            // }
            // .buttonStyle(.plain)
            // .accessibilityLabel("Convos")
            // .accessibilityIdentifier("convos-action-button")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Media buttons")
        .accessibilityIdentifier("media-buttons")
        .padding(.horizontal, DesignConstants.Spacing.step2x)
    }

    private enum Constant {
        static let buttonSize: CGFloat = 32.0
    }
}

#Preview {
    @Previewable @State var isPhotoPickerPresented: Bool = false
    @Previewable @State var isCameraPresented: Bool = false

    MessagesMediaButtonsView(
        isPhotoPickerPresented: $isPhotoPickerPresented,
        isCameraPresented: $isCameraPresented,
        onConvosAction: {}
    )
    .padding()
}
