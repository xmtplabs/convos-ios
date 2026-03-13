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
                    Text("Help groups get things done")
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
                        Text("Learn about Convos Assistants")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.colorTextPrimary)
                }
                if let privacyURL = URL(string: "https://learn.convos.org/assistants-trust-and-security") {
                    Link(destination: privacyURL) {
                        Text("Privacy & Security")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.colorTextPrimary)
                }
            }
            .listRowSeparatorTint(.colorBorderSubtle)
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
