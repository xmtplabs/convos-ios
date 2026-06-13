import SwiftUI

struct MessagesMediaButtonsView: View {
    @Binding var isPhotoPickerPresented: Bool
    @Binding var isCameraPresented: Bool
    let onVoiceMemoTap: () -> Void
    let onFilePickerTap: () -> Void
    let onConvosAction: () -> Void
    var isMediaCapacityFull: Bool = false
    var isVoiceMemoDisabled: Bool = false
    var isSideConvoDisabled: Bool = false
    var showsSideConvoButton: Bool = true
    /// File attachment button. Temporarily hidden in the Agent Builder while
    /// file attachments are disabled there; the regular chat composer keeps it.
    var showsFileButton: Bool = true
    var buttonSpacing: CGFloat = DesignConstants.Spacing.step2x
    /// Connections button (Agent Builder only). Nil hides the button — the
    /// regular chat composer doesn't surface a connections affordance here.
    var onConnectionsTap: (() -> Void)?
    /// Only rendered in DEBUG builds — the button is hidden when nil or in Release.
    var onDebugAttachmentTap: (() -> Void)?

    private var mediaTint: Color {
        isMediaCapacityFull ? Color.colorTextPrimary.opacity(0.3) : Color.colorTextPrimary
    }

    private var voiceMemoTint: Color {
        isVoiceMemoDisabled ? Color.colorTextPrimary.opacity(0.3) : Color.colorTextPrimary
    }

    var body: some View {
        HStack(spacing: buttonSpacing) {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Image(systemName: "photo.fill")
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(mediaTint)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(isMediaCapacityFull)
            .hoverEffect(.lift)
            .hoverEffectDisabled(isMediaCapacityFull)
            .accessibilityLabel("Photo library")
            .accessibilityIdentifier("photo-picker-button")

            Button {
                isCameraPresented = true
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(mediaTint)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(isMediaCapacityFull)
            .hoverEffect(.lift)
            .hoverEffectDisabled(isMediaCapacityFull)
            .accessibilityLabel("Camera")
            .accessibilityIdentifier("camera-button")

            Button {
                onVoiceMemoTap()
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(voiceMemoTint)
                    .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(isVoiceMemoDisabled)
            .hoverEffect(.lift)
            .hoverEffectDisabled(isVoiceMemoDisabled)
            .accessibilityLabel("Voice memo")
            .accessibilityIdentifier("voice-memo-button")

            if showsFileButton {
                Button {
                    onFilePickerTap()
                } label: {
                    Image(systemName: "document.fill")
                        .font(.system(size: 18.0, weight: .medium))
                        .foregroundStyle(mediaTint)
                        .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(isMediaCapacityFull)
                .hoverEffect(.lift)
                .hoverEffectDisabled(isMediaCapacityFull)
                .accessibilityLabel("Attach file")
                .accessibilityIdentifier("file-picker-button")
            }

            if let onConnectionsTap {
                Button {
                    onConnectionsTap()
                } label: {
                    Image(systemName: "batteryblock.fill")
                        .font(.system(size: 18.0, weight: .medium))
                        .foregroundStyle(.colorTextPrimary)
                        .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                .accessibilityLabel("Connections")
                .accessibilityIdentifier("connections-button")
            }

            if showsSideConvoButton {
                Button {
                    onConvosAction()
                } label: {
                    Image("convosOrangeIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 18)
                        .foregroundStyle(isSideConvoDisabled ? Color.colorTextPrimary.opacity(0.3) : Color.colorTextPrimary)
                        .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(isSideConvoDisabled)
                .hoverEffect(.lift)
                .hoverEffectDisabled(isSideConvoDisabled)
                .accessibilityLabel("Side convo")
                .accessibilityIdentifier("side-convo-button")
            }

            if let onDebugAttachmentTap {
                Button {
                    onDebugAttachmentTap()
                } label: {
                    Image(systemName: "testtube.2")
                        .font(.system(size: 18.0, weight: .medium))
                        .foregroundStyle(Color.colorTextPrimary)
                        .frame(width: Constant.buttonSize, height: Constant.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                .accessibilityLabel("Debug test attachment")
                .accessibilityIdentifier("debug-test-attachment-button")
            }
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
        onFilePickerTap: {},
        onConvosAction: {}
    )
    .padding()
}
