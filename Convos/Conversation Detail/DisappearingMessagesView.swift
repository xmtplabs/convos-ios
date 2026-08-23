import ConvosCore
import SwiftUI

enum DisappearingMessagesPreferences {
    private static let autoEnablePrefix: String = "disappearingMessages.autoEnableOnAgentPause."
    private static let preferredDurationPrefix: String = "disappearingMessages.preferredDuration."

    static func automaticallyEnableWhenAgentsPause(conversationId: String) -> Bool {
        UserDefaults.standard.bool(forKey: autoEnablePrefix + conversationId)
    }

    static func setAutomaticallyEnableWhenAgentsPause(_ enabled: Bool, conversationId: String) {
        UserDefaults.standard.set(enabled, forKey: autoEnablePrefix + conversationId)
    }

    static func preferredDuration(conversationId: String) -> DisappearingMessageDuration {
        let stored = UserDefaults.standard.object(forKey: preferredDurationPrefix + conversationId) as? NSNumber
        return stored
            .flatMap { DisappearingMessageDuration(rawValue: $0.int64Value) }
            ?? .privacyDefault
    }

    static func remember(_ duration: DisappearingMessageDuration, conversationId: String) {
        UserDefaults.standard.set(duration.rawValue, forKey: preferredDurationPrefix + conversationId)
    }
}

struct DisappearingMessagesView: View {
    @Bindable var viewModel: ConversationViewModel

    @State private var automaticallyEnableWhenAgentsPause: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var selectedDuration: DisappearingMessageDuration? {
        guard let rawValue = viewModel.conversation.disappearingMessageRetentionDurationInNs else {
            return nil
        }
        return DisappearingMessageDuration(rawValue: rawValue)
    }

    private var hasActiveTimer: Bool {
        viewModel.conversation.isDisappearingMessagesEnabled
    }

    var body: some View {
        List {
            Section {
                timerRow(title: "Off", duration: nil)
                ForEach(DisappearingMessageDuration.allCases) { duration in
                    timerRow(title: duration.title, duration: duration)
                }
            } header: {
                Text("Message timer")
            } footer: {
                Text("New messages in this conversation disappear for everyone after the selected duration.")
            }

            Section {
                Toggle(
                    "Turn on disappearing messages any time an agent is paused",
                    isOn: $automaticallyEnableWhenAgentsPause
                )
                    .onChange(of: automaticallyEnableWhenAgentsPause) { _, enabled in
                        DisappearingMessagesPreferences.setAutomaticallyEnableWhenAgentsPause(
                            enabled,
                            conversationId: viewModel.conversation.id
                        )
                    }
                    .accessibilityIdentifier("disappearing-messages-on-pause-toggle")
            } footer: {
                Text("When you pause agents in this conversation, Convos will turn on your last selected timer too.")
            }

            if viewModel.conversation.hasAgent {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                            Text("Agents can store messages outside Convos")
                                .foregroundStyle(.colorTextPrimary)
                            Text("Even with disappearing messages on, agents in this chat may store messages wherever they’re connected.")
                                .font(.footnote)
                                .foregroundStyle(.colorTextSecondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.colorCaution)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .disabled(isSaving)
        .navigationTitle("Disappearing messages")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .onAppear {
            automaticallyEnableWhenAgentsPause = DisappearingMessagesPreferences
                .automaticallyEnableWhenAgentsPause(conversationId: viewModel.conversation.id)
        }
        .alert("Timer not updated", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func timerRow(
        title: String,
        duration: DisappearingMessageDuration?
    ) -> some View {
        Button {
            update(duration)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                if isSelected(duration) {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.colorTextPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected(duration) ? "selected" : "")
        .accessibilityIdentifier("disappearing-messages-timer-\(duration?.rawValue.description ?? "off")")
    }

    private func isSelected(_ duration: DisappearingMessageDuration?) -> Bool {
        if let duration {
            return selectedDuration == duration
        }
        return !hasActiveTimer
    }

    private func update(_ duration: DisappearingMessageDuration?) {
        guard !isSelected(duration), !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await viewModel.updateDisappearingMessages(duration)
                if let duration {
                    DisappearingMessagesPreferences.remember(
                        duration,
                        conversationId: viewModel.conversation.id
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
