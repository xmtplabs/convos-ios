import SwiftUI

struct AssistantSettingsView: View {
    @Bindable private var defaults: GlobalConvoDefaults = .shared
    @Environment(\.openURL) private var openURL: OpenURLAction

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
                let learnAction = { openURL(URL(string: "https://learn.convos.org/assistants")!) }
                Button(action: learnAction) {
                    NavigationLink("Learn about Convos Assistants", destination: EmptyView())
                }
                .foregroundStyle(.colorTextPrimary)

                let privacyAction = { openURL(URL(string: "https://learn.convos.org/assistants-trust-and-security")!) }
                Button(action: privacyAction) {
                    NavigationLink("Privacy & Security", destination: EmptyView())
                }
                .foregroundStyle(.colorTextPrimary)
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
