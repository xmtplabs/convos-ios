import ConvosComposer
import ConvosCore
import SwiftUI

struct YourSpaceConversationSwitcher: View {
    let conversations: [Conversation]
    let memberNameOverride: (String) -> String?
    let onSelectConversation: (Conversation) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var query: String = ""

    private var filteredConversations: [Conversation] {
        let sorted = conversations.sorted {
            ($0.lastMessage?.createdAt ?? $0.createdAt) > ($1.lastMessage?.createdAt ?? $1.createdAt)
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            title(for: $0).localizedCaseInsensitiveContains(query)
                || ($0.lastMessage?.text.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: DesignConstants.Spacing.step3x) {
                            ZStack {
                                Circle().fill(Color.colorBackgroundInverted)
                                Image(systemName: "lock.fill")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimaryInverted)
                            }
                            .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                                Text("Your Space")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                Text("Private context across your convos")
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                            }

                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.colorTextPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("your-space-switcher-home")
                }

                Section("Convos") {
                    if conversations.isEmpty {
                        ContentUnavailableView(
                            "No convos yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Start or join a convo, then switch to it from here.")
                        )
                        .listRowBackground(Color.clear)
                    } else if filteredConversations.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredConversations) { conversation in
                            conversationButton(conversation)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("Switch")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Find a convo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func conversationButton(_ conversation: Conversation) -> some View {
        Button {
            dismiss()
            onSelectConversation(conversation)
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ConversationAvatarView(
                    conversation: conversation,
                    conversationImage: nil,
                    size: 44
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(title(for: conversation))
                        .font(isUnread(conversation) ? .body.weight(.semibold) : .body)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)
                    if let preview = conversation.lastMessage?.text, !preview.isEmpty {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                    } else {
                        Text(conversation.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                    }
                }

                Spacer(minLength: 0)

                if isUnread(conversation) {
                    Circle()
                        .fill(Color.colorLava)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(for: conversation))
        .accessibilityValue(isUnread(conversation) ? "Unread" : "")
        .accessibilityIdentifier("your-space-switcher-convo-\(conversation.id)")
    }

    private func title(for conversation: Conversation) -> String {
        conversation.computedDisplayName(memberNameOverride: memberNameOverride)
    }

    private func isUnread(_ conversation: Conversation) -> Bool {
        conversation.isUnread || conversation.agentDm?.isUnread == true
    }
}

struct YourSpaceToolsSheet: View {
    let conversations: [Conversation]
    let memberNameOverride: (String) -> String?
    @Bindable var connectionsViewModel: ConnectionsListViewModel
    @Binding var showsPeopleWidget: Bool
    @Binding var showsFootprintWidget: Bool

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            List {
                Section("Make Your Space yours") {
                    NavigationLink {
                        YourSpaceWidgetGallery(
                            showsPeopleWidget: $showsPeopleWidget,
                            showsFootprintWidget: $showsFootprintWidget
                        )
                    } label: {
                        toolsLabel("Add a widget", systemImage: "rectangle.stack.badge.plus")
                    }

                    NavigationLink {
                        ConnectionsListView(viewModel: connectionsViewModel)
                    } label: {
                        toolsLabel("Connections", systemImage: "batteryblock.fill")
                    }
                }

                Section {
                    NavigationLink {
                        YourSpaceSourcesView(
                            conversations: conversations,
                            memberNameOverride: memberNameOverride
                        )
                    } label: {
                        HStack {
                            toolsLabel("Connected convos", systemImage: "bubble.left.and.bubble.right.fill")
                            Spacer()
                            Text("\(conversations.count)")
                                .foregroundStyle(.colorTextSecondary)
                            .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Context")
                } footer: {
                    Text("Your Space stays private. Context leaves only when you choose what to share and where it should go.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("Your Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toolsLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(.colorTextPrimary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.colorTextPrimary)
                .frame(width: DesignConstants.Spacing.step8x)
        }
    }
}

private struct YourSpaceWidgetGallery: View {
    @Binding var showsPeopleWidget: Bool
    @Binding var showsFootprintWidget: Bool

    var body: some View {
        List {
            Section {
                widgetToggle(
                    title: "People pulse",
                    description: "The people active across your recent convos.",
                    systemImage: "person.3.fill",
                    isOn: $showsPeopleWidget
                )
                widgetToggle(
                    title: "Space footprint",
                    description: "A compact count of convos, people, and attention.",
                    systemImage: "square.grid.2x2.fill",
                    isOn: $showsFootprintWidget
                )
            } footer: {
                Text("Widgets use context already on this device.")
            }
        }
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func widgetToggle(
        title: String,
        description: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(.colorTextPrimary)
    }
}

private struct YourSpaceSourcesView: View {
    let conversations: [Conversation]
    let memberNameOverride: (String) -> String?

    private var sortedConversations: [Conversation] {
        conversations.sorted {
            ($0.lastMessage?.createdAt ?? $0.createdAt) > ($1.lastMessage?.createdAt ?? $1.createdAt)
        }
    }

    var body: some View {
        List(sortedConversations) { conversation in
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ConversationAvatarView(
                    conversation: conversation,
                    conversationImage: nil,
                    size: 40
                )
                .frame(width: 40, height: 40)

                Text(conversation.computedDisplayName(memberNameOverride: memberNameOverride))
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)

                Spacer()

                Label("Included", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.colorGreen)
                    .accessibilityLabel("Included in Your Space")
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView(
                    "No connected convos",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("Start or join a convo to begin growing Your Space.")
                )
            }
        }
        .navigationTitle("Connected convos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct YourSpaceShareSheet: View {
    let updates: [YourSpaceUpdate]
    let conversations: [Conversation]
    let memberNameOverride: (String) -> String?
    let onContinue: (YourSpaceUpdate, Conversation) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var selectedUpdateID: YourSpaceUpdate.ID?
    @State private var destinationID: Conversation.ID?

    private var selectedUpdate: YourSpaceUpdate? {
        updates.first { $0.id == selectedUpdateID }
    }

    private var destination: Conversation? {
        conversations.first { $0.id == destinationID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Choose the context") {
                    ForEach(updates) { update in
                        Button {
                            selectedUpdateID = update.id
                        } label: {
                            HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                                    Text(update.shareText)
                                        .font(.body)
                                        .foregroundStyle(.colorTextPrimary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(3)
                                    Text(update.date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.colorTextSecondary)
                                }
                                Spacer(minLength: 0)
                                selectionIndicator(isSelected: selectedUpdateID == update.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    ForEach(conversations) { conversation in
                        Button {
                            destinationID = conversation.id
                        } label: {
                            HStack(spacing: DesignConstants.Spacing.step3x) {
                                ConversationAvatarView(
                                    conversation: conversation,
                                    conversationImage: nil,
                                    size: 36
                                )
                                .frame(width: 36, height: 36)
                                Text(title(for: conversation))
                                    .foregroundStyle(.colorTextPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                selectionIndicator(isSelected: destinationID == conversation.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Open a convo")
                } footer: {
                    Text("Convos copies the selected context and opens the destination. Nothing is sent automatically—you decide what to paste and send.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("Share context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: continueAction) {
                    Label(continueTitle, systemImage: "doc.on.doc.fill")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(.colorBackgroundInverted, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(selectedUpdate == nil || destination == nil)
                .opacity(selectedUpdate == nil || destination == nil ? 0.4 : 1)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .background(.bar)
            }
            .onAppear {
                selectedUpdateID = selectedUpdateID ?? updates.first?.id
                destinationID = destinationID ?? conversations.first?.id
            }
        }
    }

    private var continueTitle: String {
        guard let destination else { return "Choose a convo" }
        return "Copy and open \(title(for: destination))"
    }

    private func continueAction() {
        guard let selectedUpdate, let destination else { return }
        onContinue(selectedUpdate, destination)
    }

    private func title(for conversation: Conversation) -> String {
        conversation.computedDisplayName(memberNameOverride: memberNameOverride)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.colorTextPrimary : Color.colorTextTertiary)
            .accessibilityHidden(true)
    }
}
