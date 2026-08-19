import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import SwiftUI

struct YourSpaceConversationSwitcher: View {
    let conversations: [Conversation]
    let memberNameOverride: (String) -> String?
    let onDismiss: () -> Void
    let onSelectConversation: (Conversation) -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool
    @AccessibilityFocusState private var homeAccessibilityFocused: Bool

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
        VStack(spacing: 0) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ZStack {
                    Circle().fill(Color.colorBackgroundInverted)
                    Image(systemName: "lock.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimaryInverted)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text("Your Space")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)
                    Text("Private context across every convo")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Your Space")
                .accessibilityValue("Private context across every convo")
                .accessibilityFocused($homeAccessibilityFocused)

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.colorTextPrimary)
                    .accessibilityHidden(true)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.colorTextPrimary)
                        .frame(width: 44, height: 44)
                        .background(.colorFillMinimal, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close convo switcher")
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step4x)
            .padding(.bottom, DesignConstants.Spacing.step3x)
            .accessibilityIdentifier("your-space-switcher-home")

            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                TextField("Search convos", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.colorTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: 44)
            .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.bottom, DesignConstants.Spacing.step4x)

            HStack {
                Text("Convos")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(filteredConversations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.colorTextTertiary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.bottom, DesignConstants.Spacing.step2x)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if conversations.isEmpty {
                        ContentUnavailableView(
                            "No convos yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Start or join a convo, then switch to it from here.")
                        )
                        .padding(.top, DesignConstants.Spacing.step8x)
                    } else if filteredConversations.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, DesignConstants.Spacing.step8x)
                    } else {
                        ForEach(Array(filteredConversations.enumerated()), id: \.element.id) { index, conversation in
                            conversationButton(conversation)
                                .padding(.horizontal, DesignConstants.Spacing.step4x)
                            if index < filteredConversations.count - 1 {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(.colorBackgroundRaisedSecondary)
        .onAppear {
            homeAccessibilityFocused = true
        }
    }

    private func conversationButton(_ conversation: Conversation) -> some View {
        Button {
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

enum YourSpaceToolDestination: String, Identifiable {
    case connections
    case files
    case widgets
    case connectedConvos

    var id: String { rawValue }

    var navigationTitle: String {
        switch self {
        case .connections: "Connections"
        case .files: "Files"
        case .widgets: "Widgets"
        case .connectedConvos: "Connected convos"
        }
    }
}

enum YourSpaceInputMode: String, Identifiable {
    case voice
    case chat

    var id: String { rawValue }
}

struct YourSpaceToolDestinationSheet: View {
    let destination: YourSpaceToolDestination
    let conversations: [Conversation]
    let memberNameOverride: (String) -> String?
    @Bindable var connectionsViewModel: ConnectionsListViewModel
    @Binding var showsPeopleWidget: Bool
    @Binding var showsFootprintWidget: Bool

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            Group {
                switch destination {
                case .connections:
                    ConnectionsListView(viewModel: connectionsViewModel)
                case .files:
                    YourSpaceFilesView()
                case .widgets:
                    YourSpaceWidgetGallery(
                        showsPeopleWidget: $showsPeopleWidget,
                        showsFootprintWidget: $showsFootprintWidget
                    )
                case .connectedConvos:
                    YourSpaceSourcesView(
                        conversations: conversations,
                        memberNameOverride: memberNameOverride
                    )
                }
            }
            .navigationTitle(destination.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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

private struct YourSpaceFilesView: View {
    @State private var files: [YourSpaceStoredFile] = []
    @State private var fileNotice: YourSpaceFileImportNotice?

    var body: some View {
        List {
            if !files.isEmpty {
                Section {
                    ForEach(files) { file in
                        HStack(spacing: DesignConstants.Spacing.step3x) {
                            Image(systemName: "doc.fill")
                                .font(.title3)
                                .foregroundStyle(.colorTextPrimary)
                                .frame(width: 36, height: 36)
                                .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.small))

                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                                Text(file.name)
                                    .font(.body)
                                    .foregroundStyle(.colorTextPrimary)
                                    .lineLimit(1)
                                Text(fileMetadata(file))
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteFiles)
                } footer: {
                    Text("Files stay in this app on this device, are excluded from backup, and can be deleted here.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .overlay {
            if files.isEmpty {
                ContentUnavailableView(
                    "No files yet",
                    systemImage: "folder",
                    description: Text("Choose Upload files from the More menu to add private context.")
                )
            }
        }
        .task {
            files = YourSpaceFileStore.storedFiles()
        }
        .alert(item: $fileNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func fileMetadata(_ file: YourSpaceStoredFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)
        guard file.addedAt != .distantPast else { return size }
        return "\(size) · \(file.addedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func deleteFiles(at offsets: IndexSet) {
        do {
            for index in offsets {
                try YourSpaceFileStore.deleteFile(at: files[index].url)
            }
            files.remove(atOffsets: offsets)
        } catch {
            files = YourSpaceFileStore.storedFiles()
            fileNotice = YourSpaceFileImportNotice(deletionError: error)
        }
    }
}

struct YourSpaceInputSheet: View {
    let mode: YourSpaceInputMode
    let briefing: YourSpaceBriefing

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var draft: String = ""
    @State private var submittedPrompt: String?
    @State private var response: String?
    @State private var recorder: VoiceMemoRecorder = VoiceMemoRecorder()
    @State private var isTranscribing: Bool = false
    @State private var inputError: InputError?
    @FocusState private var isChatFocused: Bool

    private let transcriber: VoiceMemoTranscriber = VoiceMemoTranscriber()
    private let transcriptionID: String = UUID().uuidString

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
                    assistantMessage(briefing.headline)

                    if let submittedPrompt {
                        userMessage(submittedPrompt)
                    }

                    if let response {
                        assistantMessage(response)
                    }

                    if submittedPrompt == nil, mode == .chat {
                        promptSuggestions
                    }

                    Label("Answers use private context already on this device.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .padding(.top, DesignConstants.Spacing.step3x)
                }
                .padding(.horizontal, DesignConstants.Spacing.step5x)
                .padding(.vertical, DesignConstants.Spacing.step8x)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(.colorBackgroundSurfaceless)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .navigationTitle("Ask your agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if mode == .voice {
                await startRecording()
            } else {
                try? await Task.sleep(for: .milliseconds(300))
                isChatFocused = true
            }
        }
        .onDisappear {
            recorder.cancelRecording()
            Task {
                await transcriber.cancel(messageId: transcriptionID)
            }
        }
        .alert(item: $inputError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var inputBar: some View {
        if mode == .chat {
            chatComposer
        } else {
            voiceComposer
        }
    }

    private var chatComposer: some View {
        HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
            TextField("Ask your agent to make, edit, or find anything", text: $draft, axis: .vertical)
                .focused($isChatFocused)
                .font(.body)
                .lineLimit(1 ... 5)
                .submitLabel(.send)
                .onSubmit { submitQuestion() }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
                .accessibilityIdentifier("your-space-chat-input")

            Button {
                submitQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(width: 44, height: 44)
                    .background(.colorFillPrimary, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .accessibilityLabel("Ask your agent")
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(.bar)
    }

    @ViewBuilder
    private var voiceComposer: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            switch recorder.state {
            case .idle:
                Button {
                    Task { await startRecording() }
                } label: {
                    Label("Start listening", systemImage: "waveform")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(.colorLava, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("your-space-start-listening-button")

            case .recording:
                VoiceMemoRecordingView(recorder: recorder)
                    .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))

            case let .recorded(url, duration):
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Text("Review your question")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)

                    VoiceMemoReviewView(
                        audioURL: url,
                        duration: duration,
                        levels: recorder.audioLevels,
                        onSend: { transcribe(url: url) }
                    )

                    Button("Discard", role: .destructive) {
                        recorder.cancelRecording()
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal, DesignConstants.Spacing.step3x)
            }

            if isTranscribing {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    ProgressView()
                    Text("Understanding your question…")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(.bar)
    }

    private var promptSuggestions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                suggestionButton("What needs me?")
                suggestionButton("What's new?")
                suggestionButton("Who is active?")
            }
        }
        .scrollIndicators(.hidden)
    }

    private func suggestionButton(_ title: String) -> some View {
        Button(title) {
            submitQuestion(title)
        }
        .font(.subheadline.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private func assistantMessage(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.colorTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DesignConstants.Spacing.step4x)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            .frame(maxWidth: 560, alignment: .leading)
            .accessibilityLabel("Your Space: \(text)")
    }

    private func userMessage(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.colorTextPrimaryInverted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DesignConstants.Spacing.step4x)
            .background(.colorBackgroundInverted, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            .frame(maxWidth: 560, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("You: \(text)")
    }

    private func submitQuestion(_ suppliedQuestion: String? = nil) {
        let question = (suppliedQuestion ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        submittedPrompt = question
        response = groundedResponse(to: question)
        draft = ""
    }

    private func groundedResponse(to question: String) -> String {
        let normalized = question.lowercased()

        if normalized.contains("need") || normalized.contains("attention") || normalized.contains("reply") {
            guard !briefing.attentionUpdates.isEmpty else {
                return "Nothing in your current briefing needs your attention right now."
            }
            let titles = briefing.attentionUpdates.prefix(3).map(\.conversationTitle)
            let remainder = briefing.attentionCount - titles.count
            let suffix = remainder > 0 ? " and \(remainder) more" : ""
            return "Start with \(titles.joined(separator: ", "))\(suffix). They have unread or pending context."
        }

        if normalized.contains("new") || normalized.contains("update") || normalized.contains("changed") {
            guard !briefing.recentUpdates.isEmpty else {
                return "There aren't any recent updates yet. Your Space will fill in as your convos grow."
            }
            return briefing.recentUpdates
                .prefix(3)
                .map { "\($0.conversationTitle): \($0.detail)" }
                .joined(separator: "\n\n")
        }

        if normalized.contains("who") || normalized.contains("people") || normalized.contains("active") {
            let peopleWord = briefing.peopleCount == 1 ? "person" : "people"
            let convoWord = briefing.sourceCount == 1 ? "convo" : "convos"
            return "Your Space currently connects \(briefing.peopleCount) \(peopleWord) across \(briefing.sourceCount) \(convoWord)."
        }

        return "Here's the clearest signal I have right now: \(briefing.headline)"
    }

    private func startRecording() async {
        guard case .idle = recorder.state else { return }
        guard await VoiceMemoRecorder.ensureRecordPermission() else {
            inputError = InputError(
                title: "Microphone access needed",
                message: "Allow microphone access in Settings to talk to Your Space. You can still use chat."
            )
            return
        }

        do {
            try recorder.startRecording()
        } catch {
            inputError = InputError(title: "Couldn't start listening", message: error.localizedDescription)
        }
    }

    private func transcribe(url: URL) {
        guard !isTranscribing else { return }
        isTranscribing = true
        Task {
            do {
                let transcript = try await transcriber.transcribe(messageId: transcriptionID, fileURL: url)
                recorder.cancelRecording()
                isTranscribing = false
                submitQuestion(transcript)
            } catch {
                isTranscribing = false
                inputError = InputError(
                    title: "Couldn't understand that",
                    message: "Try recording again or use chat instead. \(error.localizedDescription)"
                )
            }
        }
    }

    private struct InputError: Identifiable {
        let id: UUID = UUID()
        let title: String
        let message: String
    }
}
