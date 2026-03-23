import SwiftUI

struct AssistantsInfoView: View {
    var isConfirmation: Bool = false
    var onConfirm: (() -> Void)?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    private let horizontalPadding: CGFloat = DesignConstants.Spacing.step10x

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Group {
                Text("Private chat for the AI era")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)

                TightLineHeightText(text: "Assistants help groups do things", fontSize: 40, lineHeight: 40)

                Text("Assistants learn by listening. They can only see and act in one convo.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text("They have tools to get things done in the real world.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, horizontalPadding)

            abilitiesScroller

            VStack(spacing: DesignConstants.Spacing.step2x) {
                if isConfirmation {
                    let confirmAction = {
                        onConfirm?()
                        dismiss()
                    }
                    Button(action: confirmAction) {
                        Text("Add an instant assistant")
                    }
                    .convosButtonStyle(.rounded(fullWidth: true))
                } else {
                    let dismissAction = { dismiss() }
                    Button(action: dismissAction) {
                        Text("Awesome")
                    }
                    .convosButtonStyle(.rounded(fullWidth: true))
                }

                let learnMoreURL = URL(string: "https://learn.convos.org/assistants")
                let learnMoreAction = { if let learnMoreURL { openURL(learnMoreURL) } }
                Button(action: learnMoreAction) {
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Text("Learn more")
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
                abilityPill(icon: "message.fill", label: "Texting", color: .colorTexting)
                abilityPill(icon: "envelope.fill", label: "Email", color: .colorEmail)
                abilityPill(icon: "pointer.arrow", label: "Internet", color: .colorInternet)
                abilityPill(icon: "checklist", label: "Organize", color: .colorOrganize)
                abilityPill(icon: "calendar", label: "Remind", color: .colorReminders)
                abilityPill(icon: "photo.fill", label: "Photos", color: .colorPhotos, foreground: .colorTextPrimaryInverted)
                abilityPill(icon: "cloud.fill", label: "AI", color: .colorAI)
            }
            .padding(.horizontal, horizontalPadding)
        }
    }

    private func abilityPill(icon: String, label: String, color: Color, foreground: Color = .white) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: icon)
                .font(.body)
            Text(label)
                .font(.body)
                .fontWeight(.medium)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(color, in: .capsule)
    }
}

#Preview("Info") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { AssistantsInfoView().padding(.top, 20) }
}

#Preview("Confirmation") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) {
            AssistantsInfoView(isConfirmation: true, onConfirm: { }).padding(.top, 20)
        }
}
