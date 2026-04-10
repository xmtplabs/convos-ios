import SwiftUI

struct MessagesMediaButtonsView: View {
    @Binding var isPhotoPickerPresented: Bool
    @Binding var isCameraPresented: Bool
    let onVoiceMemoTap: () -> Void
    let onConvosAction: () -> Void
    var isSideConvoDisabled: Bool = false

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Image(systemName: "photo.fill")
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(Color.colorTextPrimary)
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
                    .foregroundStyle(Color.colorTextPrimary)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera")
            .accessibilityIdentifier("camera-button")

            Button {
                onVoiceMemoTap()
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(Color.colorTextPrimary)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice memo")
            .accessibilityIdentifier("voice-memo-button")

            Button {
                onConvosAction()
            } label: {
                Image("convosOrangeIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 18)
                    .foregroundStyle(isSideConvoDisabled ? Color.colorTextSecondary.opacity(0.3) : Color.colorTextSecondary)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(isSideConvoDisabled)
            .accessibilityLabel("Side convo")
            .accessibilityIdentifier("side-convo-button")
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
        onVoiceMemoTap: {},
        onConvosAction: {}
    )
    .padding()
}
