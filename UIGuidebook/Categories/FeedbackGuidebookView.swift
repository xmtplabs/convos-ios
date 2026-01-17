import SwiftUI

struct FeedbackGuidebookView: View {
    @State private var drainingResetId: UUID = UUID()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                errorViewSection
                pulsingCircleSection
                drainingCapsuleSection
                qrCodeSection
                flashingListRowSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var errorViewSection: some View {
        ComponentShowcase(
            "ErrorView",
            description: "Displays error message with optional retry button"
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("With Retry Button:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .center, spacing: 16) {
                        Text("Something went wrong. Please try again.")
                            .font(.body)
                            .foregroundStyle(.colorTextSecondary)
                            .multilineTextAlignment(.center)

                        Button("Retry") {}
                            .convosButtonStyle(.text)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.background)
                    )
                }

                VStack(spacing: 8) {
                    Text("Without Retry Button:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .center, spacing: 16) {
                        Text("Network connection lost.")
                            .font(.body)
                            .foregroundStyle(.colorTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.background)
                    )
                }
            }
        }
    }

    private var pulsingCircleSection: some View {
        ComponentShowcase(
            "PulsingCircleView",
            description: "Animated pulsing circles for loading/typing indicators"
        ) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Typing Indicator (3 circles)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PulsingCircleView(.typingIndicator)
                }

                Divider()

                VStack(spacing: 8) {
                    Text("Loading Indicator (single)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PulsingCircleView(.loadingIndicator)
                }

                Divider()

                VStack(spacing: 8) {
                    Text("Progress Indicator (5 circles)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PulsingCircleView(.progressIndicator)
                }

                Divider()

                VStack(spacing: 8) {
                    Text("Custom Configuration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PulsingCircleView(
                        configuration: .init(
                            count: 4,
                            size: 12,
                            color: .colorOrange,
                            spacing: 8,
                            animationDuration: 1.2,
                            axis: .horizontal,
                            scaleRange: 0.3...1.5,
                            opacityRange: 0.2...1.0
                        )
                    )
                }
            }
        }
    }

    private var drainingCapsuleSection: some View {
        ComponentShowcase(
            "DrainingCapsule",
            description: "Animated progress bar that drains from full to empty over a duration"
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    DrainingCapsule(
                        fillColor: .colorFillPrimary,
                        backgroundColor: .colorFillSecondary,
                        duration: 3.0
                    )
                    .frame(height: 8)
                    .id(drainingResetId)
                    Text("3 second duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    DrainingCapsule(
                        fillColor: .colorOrange,
                        backgroundColor: .colorFillSecondary,
                        duration: 5.0
                    )
                    .frame(height: 12)
                    .id(drainingResetId)
                    Text("5 second duration (orange)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    DrainingCapsule(
                        fillColor: .colorCaution,
                        backgroundColor: .colorCaution.opacity(0.2),
                        duration: 2.0
                    )
                    .frame(height: 6)
                    .id(drainingResetId)
                    Text("2 second duration (caution)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let resetAction = {
                    drainingResetId = UUID()
                }
                Button("Restart Animations", action: resetAction)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var qrCodeSection: some View {
        ComponentShowcase(
            "QRCodeView",
            description: "Generates QR codes from URLs with customizable colors and optional center image"
        ) {
            VStack(spacing: 16) {
                Text("QRCodeView requires ConvosCoreiOS for QR code generation. It supports:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Custom foreground/background colors", systemImage: "paintpalette")
                    Label("Center image overlay", systemImage: "photo")
                    Label("Share link functionality", systemImage: "square.and.arrow.up")
                    Label("Auto-regenerates on color scheme change", systemImage: "moon")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.background)
                        .frame(width: 120, height: 120)
                    Image(systemName: "qrcode")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .foregroundStyle(.primary)
                }

                Text("Usage: QRCodeView(url:backgroundColor:foregroundColor:centerImage:)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var flashingListRowSection: some View {
        ComponentShowcase(
            "FlashingListRowButton",
            description: "List row with flash feedback animation on tap"
        ) {
            VStack(spacing: 0) {
                FlashingListRowButton(action: {}) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Settings")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()
                    .padding(.leading, 44)

                FlashingListRowButton(action: {}) {
                    HStack {
                        Image(systemName: "person")
                        Text("Profile")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()
                    .padding(.leading, 44)

                FlashingListRowButton(action: {}) {
                    HStack {
                        Image(systemName: "bell")
                        Text("Notifications")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background)
            )
        }
    }
}

#Preview {
    NavigationStack {
        FeedbackGuidebookView()
            .navigationTitle("Feedback")
    }
}
