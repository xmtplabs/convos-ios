import ConvosCore
import ConvosCoreiOS
import SwiftUI

struct VoiceMemoRecordingView: View {
    @Bindable var recorder: VoiceMemoRecorder

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1.5

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Canvas { context, size in
                let totalBarWidth = barWidth + barSpacing
                let visibleBarCount = max(Int(size.width / totalBarWidth), 1)
                let levels = recorder.audioLevels
                let placeholderHeight: CGFloat = 2
                let recordedCount = min(levels.count, visibleBarCount)
                let startIndex = max(levels.count - visibleBarCount, 0)

                for i in 0 ..< visibleBarCount {
                    let x = CGFloat(i) * totalBarWidth

                    let barIndex = i - (visibleBarCount - recordedCount)
                    if barIndex >= 0, barIndex + startIndex < levels.count {
                        let level = CGFloat(levels[startIndex + barIndex])
                        let height = max(size.height * level, placeholderHeight)
                        let y = (size.height - height) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                        let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                        context.fill(path, with: .color(.colorCaution))
                    } else {
                        let y = (size.height - placeholderHeight) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: placeholderHeight)
                        let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                        context.fill(path, with: .color(Color.colorCaution.opacity(0.3)))
                    }
                }
            }
            .frame(height: 24)

            Text(formattedDuration(recorder.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.colorTextSecondary)
                .frame(minWidth: 36, alignment: .trailing)

            Button {
                withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                    recorder.stopRecording()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.colorCaution, in: Circle())
            }
            .accessibilityLabel("Stop recording")
            .accessibilityIdentifier("voice-memo-stop-button")
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step4x)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct VoiceMemoKeyboardFocusKeeper: View {
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    @Binding var text: String

    init(focusState: FocusState<MessagesViewInputFocus?>.Binding, text: Binding<String>) {
        _focusState = focusState
        _text = text
    }

    var body: some View {
        TextField("", text: $text)
            .focused($focusState, equals: .voiceMemoRecording)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview {
    @Previewable @FocusState var focusState: MessagesViewInputFocus?

    VoiceMemoRecordingView(recorder: VoiceMemoRecorder())
        .padding()
}
