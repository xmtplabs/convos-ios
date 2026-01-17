import SwiftUI

struct ButtonsGuidebookView: View {
    @State private var isDisabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Toggle("Show Disabled State", isOn: $isDisabled)
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                outlineButtonSection
                roundedButtonSection
                roundedDestructiveButtonSection
                textButtonSection
                actionButtonSection
                holdToConfirmSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var outlineButtonSection: some View {
        ComponentShowcase(
            "OutlineButtonStyle",
            description: "Bordered button with transparent background. Use .convosButtonStyle(.outline(fullWidth:))"
        ) {
            VStack(spacing: 12) {
                Button("Outline Button") {}
                    .convosButtonStyle(.outline(fullWidth: true))
                    .disabled(isDisabled)

                Button("Another Outline") {}
                    .convosButtonStyle(.outline(fullWidth: true))
                    .disabled(isDisabled)
            }
        }
    }

    private var roundedButtonSection: some View {
        ComponentShowcase(
            "RoundedButtonStyle",
            description: "Capsule-shaped primary button. Use .convosButtonStyle(.rounded(fullWidth:, backgroundColor:))"
        ) {
            VStack(spacing: 12) {
                Button("Primary Action") {}
                    .convosButtonStyle(.rounded(fullWidth: true))
                    .disabled(isDisabled)

                Button("Custom Color") {}
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorOrange))
                    .disabled(isDisabled)
            }
        }
    }

    private var roundedDestructiveButtonSection: some View {
        ComponentShowcase(
            "RoundedDestructiveButtonStyle",
            description: "Capsule button with destructive (caution) styling"
        ) {
            VStack(spacing: 12) {
                Button("Delete") {}
                    .buttonStyle(RoundedDestructiveButtonStyle(fullWidth: true))
                    .disabled(isDisabled)

                Button("Remove Item") {}
                    .buttonStyle(RoundedDestructiveButtonStyle(fullWidth: true))
                    .disabled(isDisabled)
            }
        }
    }

    private var textButtonSection: some View {
        ComponentShowcase(
            "TextButtonStyle",
            description: "Minimal text-only button. Use .convosButtonStyle(.text)"
        ) {
            VStack(spacing: 12) {
                Button("Cancel") {}
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
                    .disabled(isDisabled)

                Button("Skip") {}
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
                    .disabled(isDisabled)

                Button("Learn More") {}
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
                    .disabled(isDisabled)
            }
        }
    }

    private var actionButtonSection: some View {
        ComponentShowcase(
            "ActionButtonStyle",
            description: "Sheet action button with icon. Use .convosButtonStyle(.action(iconColor:, isDestructive:))"
        ) {
            VStack(spacing: 12) {
                let messageAction = {
                    // Action
                }
                Button(action: messageAction) {
                    HStack {
                        Image(systemName: "message.fill")
                            .foregroundColor(.primary)
                        Text("Message")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
                .convosButtonStyle(.action())
                .disabled(isDisabled)

                let deleteAction = {
                    // Action
                }
                Button(action: deleteAction) {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                        Text("Delete")
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
                .convosButtonStyle(.action(isDestructive: true))
                .disabled(isDisabled)
            }
        }
    }

    private var holdToConfirmSection: some View {
        ComponentShowcase(
            "HoldToConfirmPrimitiveStyle",
            description: "Long-press button with progress indicator for destructive actions"
        ) {
            VStack(spacing: 16) {
                Button {} label: {
                    Text("Hold to Confirm")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoldToConfirmPrimitiveStyle(duration: 2.0))
                .disabled(isDisabled)

                Button {} label: {
                    Text("Custom Duration (3s)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HoldToConfirmPrimitiveStyle(
                    config: HoldToConfirmStyleConfig(
                        duration: 3.0,
                        backgroundColor: .colorCaution
                    )
                ))
                .disabled(isDisabled)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ButtonsGuidebookView()
            .navigationTitle("Buttons")
    }
}
