import SwiftUI

struct CustomizeSettingsView: View {
    @State private var revealModeEnabled: Bool = GlobalConvoDefaults.shared.revealModeEnabled
    @State private var includeInfoWithInvites: Bool = GlobalConvoDefaults.shared.includeInfoWithInvites

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
                    isOn: $revealModeEnabled
                )

                customizeToggleRow(
                    symbolName: "qrcode",
                    title: "Include info with invites",
                    subtitle: "When enabled, anyone with your convo code can see its pic, name and description",
                    isOn: $includeInfoWithInvites
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
        .onChange(of: revealModeEnabled) { _, value in
            GlobalConvoDefaults.shared.revealModeEnabled = value
        }
        .onChange(of: includeInfoWithInvites) { _, value in
            GlobalConvoDefaults.shared.includeInfoWithInvites = value
        }
    }

    @ViewBuilder
    private func customizeToggleRow(
        symbolName: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
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
        }
    }
}

#Preview {
    NavigationStack {
        CustomizeSettingsView()
    }
}
