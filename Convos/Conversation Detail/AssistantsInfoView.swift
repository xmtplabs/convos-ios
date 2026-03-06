import SwiftUI

struct AssistantsInfoView: View {
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    private let horizontalPadding: CGFloat = DesignConstants.Spacing.step10x

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Group {
                Text("Private chat for the AI world")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)

                Text("Assistants help groups do things")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)

                Text("Assistants learn by listening. They can only see and act in one convo.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text("They have tools to get things done in the real world.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, horizontalPadding)

            abilitiesScroller

            VStack(spacing: DesignConstants.Spacing.step2x) {
                let dismissAction = { dismiss() }
                Button(action: dismissAction) {
                    Text("Awesome")
                }
                .convosButtonStyle(.rounded(fullWidth: true))

                let trustURL = URL(string: "https://learn.convos.org/assistants-trust-and-security")
                let trustAction = { if let trustURL { openURL(trustURL) } }
                Button(action: trustAction) {
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Text("Trust and Security")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundStyle(.colorFillTertiary)
                    }
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : DesignConstants.Spacing.step6x)
        .sheetDragIndicator(.hidden)
    }

    private var abilitiesScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                abilityPill(icon: "message.fill", label: "Texting")
                abilityPill(icon: "waveform", label: "Phone calls")
                abilityPill(icon: "envelope.fill", label: "Email")
            }
            .padding(.horizontal, horizontalPadding)
        }
    }

    private func abilityPill(icon: String, label: String) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: icon)
                .font(.body)
            Text(label)
                .font(.body)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.colorLava, in: .capsule)
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { AssistantsInfoView().padding(.top, 20) }
}
