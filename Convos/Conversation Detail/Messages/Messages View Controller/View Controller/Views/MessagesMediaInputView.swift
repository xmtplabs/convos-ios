import SwiftUI

struct MessagesMediaInputView: View {
    @Binding var isPhotoPickerPresented: Bool
    @Binding var isCameraPresented: Bool
    let isExpanded: Bool
    let onCollapse: () -> Void
    let onConvosAction: () -> Void

    var body: some View {
        if isExpanded {
            chevronButton
        } else {
            actionButtons
        }
    }

    private var chevronButton: some View {
        Button {
            onCollapse()
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 18.0, weight: .medium))
                .foregroundStyle(Color.colorTextSecondary)
                .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show media buttons")
        .accessibilityIdentifier("collapse-input-button")
    }

    private var actionButtons: some View {
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

            // TODO: Convos action button (hidden until feature is ready)
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
        .padding(.horizontal, DesignConstants.Spacing.step2x)
    }

    private enum Constant {
        static let buttonSize: CGFloat = 32.0
    }
}

#Preview("Collapsed") {
    @Previewable @State var isPhotoPickerPresented: Bool = false
    @Previewable @State var isCameraPresented: Bool = false

    MessagesMediaInputView(
        isPhotoPickerPresented: $isPhotoPickerPresented,
        isCameraPresented: $isCameraPresented,
        isExpanded: false,
        onCollapse: {},
        onConvosAction: {}
    )
    .padding()
}

#Preview("Expanded") {
    @Previewable @State var isPhotoPickerPresented: Bool = false
    @Previewable @State var isCameraPresented: Bool = false

    MessagesMediaInputView(
        isPhotoPickerPresented: $isPhotoPickerPresented,
        isCameraPresented: $isCameraPresented,
        isExpanded: true,
        onCollapse: {},
        onConvosAction: {}
    )
    .padding()
}
