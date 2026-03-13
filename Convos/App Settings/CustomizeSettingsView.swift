import SwiftUI

struct CustomizeSettingsView: View {
    @Bindable private var defaults: GlobalConvoDefaults = .shared

    private var blurIncomingPhotosBinding: Binding<Bool> {
        Binding(
            // UI toggle represents blur-on, so it is the inverse of auto-reveal.
            get: { !defaults.autoRevealPhotos },
            set: { defaults.autoRevealPhotos = !$0 }
        )
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Customize")
                        .font(.convosTitle)
                        .tracking(Font.convosTitleTracking)
                        .foregroundStyle(.colorTextPrimary)
                    Text("Your new convos")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextPrimary)
                }
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)
            .listRowSpacing(0.0)
            .listRowInsets(.all, DesignConstants.Spacing.step2x)
            .listSectionMargins(.top, 0.0)
            .listSectionSeparator(.hidden)

            Section {
                customizeToggleRow(
                    symbolName: "eye.slash",
                    title: "Reveal mode",
                    subtitle: "Blur incoming pics",
                    isOn: blurIncomingPhotosBinding,
                    toggleAccessibilityIdentifier: "customize-reveal-mode-toggle"
                )

                customizeToggleRow(
                    symbolName: "qrcode",
                    title: "Include info with invites",
                    subtitle: "When enabled, anyone with your convo code can see its pic, name and description",
                    isOn: $defaults.includeInfoWithInvites,
                    toggleAccessibilityIdentifier: "customize-include-info-toggle"
                )
            }

            Section {
                HStack {
                    Text("Colors")
                        .foregroundStyle(.colorTextTertiary)
                    Spacer()
                    SoonLabel()
                }
            }
            .disabled(true)
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func customizeToggleRow(
        symbolName: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        toggleAccessibilityIdentifier: String
    ) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: symbolName)
                .font(.headline)
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .padding(.vertical, 10.0)
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 40.0, height: 40.0)
                .background(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                        .fill(Color.colorFillMinimal)
                        .aspectRatio(1.0, contentMode: .fit)
                )

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(3)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityIdentifier(toggleAccessibilityIdentifier)
        }
    }
}

#Preview {
    NavigationStack {
        CustomizeSettingsView()
    }
}
