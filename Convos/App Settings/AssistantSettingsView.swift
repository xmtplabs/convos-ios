import SwiftUI

struct AssistantSettingsView: View {
    @Bindable private var defaults: GlobalConvoDefaults = .shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Assistants")
                        .font(.convosTitle)
                        .tracking(Font.convosTitleTracking)
                        .foregroundStyle(.colorTextPrimary)
                    Text("Help groups do things")
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
                Toggle(isOn: $defaults.assistantsEnabled) {
                    Text("Instant assistant")
                        .foregroundStyle(.colorTextPrimary)
                }
                .accessibilityIdentifier("assistants-enabled-toggle")
            } footer: {
                Text("Swipe up in new convos")
            }

            Section {
                if let learnURL = URL(string: "https://learn.convos.org/assistants") {
                    Link(destination: learnURL) {
                        HStack {
                            Text("Learn about assistants")
                                .foregroundStyle(.colorTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.colorTextTertiary)
                        }
                    }
                }
            } footer: {
                Text("Capabilities, privacy and security")
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AssistantSettingsView()
    }
}
