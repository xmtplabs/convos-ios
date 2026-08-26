import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import PhotosUI
import SwiftUI
import UIKit

struct DocRootView: View {
    @Bindable private var conversationsViewModel: ConversationsViewModel
    private let profileSettingsViewModel: ProfileSettingsViewModel
    private let coreActions: any CoreActions
    @State private var viewModel: DocExperienceViewModel
    @State private var isPresentingSettings: Bool = false
    @State private var isPresentingConnectPreview: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    init(
        conversationsViewModel: ConversationsViewModel,
        profileSettingsViewModel: ProfileSettingsViewModel,
        coreActions: any CoreActions
    ) {
        self.conversationsViewModel = conversationsViewModel
        self.profileSettingsViewModel = profileSettingsViewModel
        self.coreActions = coreActions
        let model = DocExperienceViewModel(
            session: conversationsViewModel.session,
            coreActions: coreActions
        )
        _viewModel = State(initialValue: model)
        _isPresentingConnectPreview = State(initialValue: model.previewStage == .connect)
    }

    var body: some View {
        Group {
            if viewModel.previewStage == .welcome ||
                (viewModel.previewStage == nil && !viewModel.hasCompletedWelcome) {
                DocWelcomeView {
                    if reduceMotion {
                        viewModel.completeWelcome()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewModel.completeWelcome()
                        }
                    }
                }
            } else {
                NavigationStack {
                    DocHomeView(
                        viewModel: viewModel,
                        onSettings: { isPresentingSettings = true },
                        onConnectGoogle: {
                            if viewModel.previewStage == nil {
                                viewModel.isPresentingGoogleConnect = true
                            } else {
                                isPresentingConnectPreview = true
                            }
                        }
                    )
                    .navigationDestination(for: DocStatus.self) { doc in
                        DocRoomPlaceholderView(doc: doc)
                    }
                }
            }
        }
        .tint(.blue)
        .task {
            await viewModel.startAgentIfNeeded()
        }
        .task(id: viewModel.agentBindingKey) {
            await viewModel.synchronizeAgentDm()
        }
        .onChange(of: viewModel.dmViewModel?.conversation.id) { _, dmId in
            guard dmId != nil else { return }
            viewModel.showGoogleConnectIfNeeded()
        }
        .sheet(
            isPresented: $viewModel.isPresentingGoogleConnect,
            onDismiss: viewModel.didDismissGoogleConnect
        ) {
            if let conversation = viewModel.googleConnectConversation {
                CloudConnectionGrantRequestSheet(
                    viewModel: CloudConnectionGrantRequestSheetViewModel(
                        serviceId: "googledocs",
                        conversationId: conversation.id,
                        conversation: conversation,
                        session: conversationsViewModel.session
                    ),
                    onDismiss: viewModel.didDismissGoogleConnect
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $isPresentingConnectPreview) {
            CloudConnectionGrantRequestSheet(
                viewModel: CloudConnectionGrantRequestSheetViewModel(
                    serviceId: "googledocs",
                    conversationId: "doc-preview",
                    conversation: nil,
                    session: conversationsViewModel.session,
                    previewingDisconnectedService: true
                ),
                onDismiss: { isPresentingConnectPreview = false }
            )
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $isPresentingSettings) {
            AppSettingsView(
                viewModel: conversationsViewModel.appSettingsViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                session: conversationsViewModel.session,
                coreActions: coreActions,
                onDeleteAllData: conversationsViewModel.deleteAllData
            )
        }
        .sheet(isPresented: $viewModel.isPresentingHistory) {
            if let conversationViewModel = viewModel.conversationViewModel {
                NewConversationView(
                    viewModel: conversationViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    initialAgentDmInboxId: viewModel.agentInboxId
                )
            } else {
                ContentUnavailableView(
                    "History is preparing",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Doc's private chat will appear here when it is ready.")
                )
            }
        }
        .shareSheet(
            isPresented: $viewModel.isPresentingShareNumber,
            items: viewModel.shareText.map { [$0] } ?? [],
            applicationActivities: viewModel.sharedDocNumber.map {
                [DocCopyNumberActivity(number: $0)]
            }
        )
    }
}

private struct DocWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: DesignConstants.Spacing.step8x)
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 56.0, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 96.0, height: 96.0)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 24.0))
                        .accessibilityHidden(true)

                    Text("Doc")
                        .font(.largeTitle.bold())
                        .padding(.top, DesignConstants.Spacing.step6x)

                    Text("Doc turns your group's iMessage thread into a living doc")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, DesignConstants.Spacing.step3x)
                        .padding(.horizontal, DesignConstants.Spacing.step8x)

                    Spacer(minLength: DesignConstants.Spacing.step8x)

                    Button("Continue", action: onContinue)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44.0)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)
                        .padding(.bottom, DesignConstants.Spacing.step6x)
                        .accessibilityIdentifier("doc-welcome-continue")
                }
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("doc-welcome")
    }
}

private struct DocHomeView: View {
    @Bindable var viewModel: DocExperienceViewModel
    let onSettings: () -> Void
    let onConnectGoogle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                if viewModel.shouldShowGoogleConnectCard {
                    DocGoogleConnectCard(onConnect: onConnectGoogle)
                }

                if !viewModel.visiblePendingItems.isEmpty {
                    Text("For you")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, DesignConstants.Spacing.step2x)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(viewModel.visiblePendingItems) { item in
                        DocWaitingItemCard(
                            item: item,
                            sendState: viewModel.sendState(for: item),
                            isEnabled: viewModel.isDmReadyForDisplay,
                            onAnswer: { viewModel.sendAnswer($0, for: item) },
                            onRetry: { viewModel.retryAnswer(for: item) }
                        )
                    }
                }

                if viewModel.docs.isEmpty {
                    DocEmptyState(isPreparing: viewModel.isPreparingAgent)
                } else {
                    ForEach(viewModel.docs) { doc in
                        DocStatusCard(
                            doc: doc,
                            onShare: { viewModel.presentShareNumber(for: doc) }
                        )
                        .transition(
                            .opacity.combined(with: .move(edge: reduceMotion ? .bottom : .top))
                        )
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.bottom, DesignConstants.Spacing.step6x)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.3),
                value: viewModel.docs.map(\.id)
            )
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Doc")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .frame(minWidth: 44.0, minHeight: 44.0)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("doc-settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DocComposer(viewModel: viewModel)
        }
        .accessibilityIdentifier("doc-home")
    }
}

private struct DocGoogleConnectCard: View {
    let onConnect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32.0, height: 32.0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Connect Google Docs")
                    .font(.subheadline.weight(.semibold))
                Text("Doc needs it to write your docs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Connect", action: onConnect)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(minHeight: 44.0)
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14.0))
        .accessibilityIdentifier("doc-google-connect-card")
    }
}

private struct DocEmptyState: View {
    let isPreparing: Bool

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Spacer(minLength: 72.0)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42.0, weight: .medium))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("Screenshot your group's thread and send it here")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(isPreparing ? "Doc is getting ready. You can choose screenshots now." : "Choose one or more screenshots below to start your first living doc.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 72.0)
        }
        .frame(maxWidth: 420.0)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("doc-empty-state")
    }
}

private struct DocStatusCard: View {
    let doc: DocStatus
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            NavigationLink(value: doc) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step2x) {
                        Circle()
                            .fill(freshnessColor)
                            .frame(width: 9.0, height: 9.0)
                            .accessibilityLabel(freshnessLabel)
                        Text(doc.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }

                    Text("\(doc.lastChange.who) \(doc.lastChange.what) · \(compactRelativeTime(from: doc.lastChange.at))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    bindingPill
                    metadataPills
                }

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    bindingPill
                    metadataPills
                }
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16.0))
        .overlay {
            RoundedRectangle(cornerRadius: 16.0)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1.0)
        }
        .contentShape(.rect)
        .accessibilityIdentifier("doc-card-\(doc.id)")
    }

    @ViewBuilder
    private var metadataPills: some View {
        if let dates = doc.dates {
            metadataPill(systemImage: "calendar", text: dates)
        }
        if let people = doc.people {
            metadataPill(systemImage: "person.2", text: "\(people)")
        }
    }

    @ViewBuilder
    private var bindingPill: some View {
        if doc.binding.state == .live {
            Label("In the group", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .frame(minHeight: 28.0)
                .background(Color.green.opacity(0.12), in: Capsule())
        } else {
            Button(action: onShare) {
                Label("Share Doc's number", systemImage: "person.badge.plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(minHeight: 44.0)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .accessibilityIdentifier("doc-share-number")
        }
    }

    private func metadataPill(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: 28.0)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    private var freshnessColor: Color {
        let age = Date().timeIntervalSince(doc.updatedAt)
        if age < 24 * 60 * 60 { return .accentColor }
        return Color(uiColor: .systemGray3)
    }

    private var freshnessLabel: String {
        let age = Date().timeIntervalSince(doc.updatedAt)
        if age < 60 * 60 { return "Updated recently" }
        if age < 24 * 60 * 60 { return "Updated today" }
        return "Not recently updated"
    }

    private func compactRelativeTime(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 60 * 60 { return "\(seconds / 60)m" }
        if seconds < 24 * 60 * 60 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

private struct DocComposer: View {
    @Bindable var viewModel: DocExperienceViewModel
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    @FocusState private var focus: MessagesViewInputFocus?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    private var dmViewModel: ConversationViewModel? {
        viewModel.dmViewModel
    }

    private var messageText: Binding<String> {
        Binding(
            get: { dmViewModel?.messageText ?? "" },
            set: { dmViewModel?.messageText = $0 }
        )
    }

    private var pendingAttachments: [PendingMediaAttachment] {
        dmViewModel?.pendingMediaAttachments ?? []
    }

    private var pendingPhotoCount: Int {
        pendingAttachments.reduce(into: 0) { count, attachment in
            if case .photo = attachment { count += 1 }
        }
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            if viewModel.pendingScreenshotCount > 0 {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressText)
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .frame(minHeight: 32.0)
                .background(.thinMaterial, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("doc-reading-progress")
            }

            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        ForEach(pendingAttachments) { attachment in
                            DocAttachmentThumbnail(attachment: attachment) {
                                dmViewModel?.removeMediaAttachment(id: attachment.id)
                            }
                        }
                    }
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: DesignConstants.Spacing.step2x) {
                    messageField
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        historyButton
                        photoPicker
                        Spacer()
                        sendButton
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                    historyButton
                    photoPicker
                    messageField
                    sendButton
                }
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.top, DesignConstants.Spacing.step2x)
        .padding(.bottom, DesignConstants.Spacing.step2x)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .focusCoordinatorSync(
            focusState: $focus,
            coordinator: focusCoordinator,
            resetToken: dmViewModel?.conversation.id
        )
        .onChange(of: selectedPhotos) { _, photos in
            load(photos)
        }
    }

    private var progressText: String {
        let count = viewModel.pendingScreenshotCount
        return "Doc is reading \(count) screenshot\(count == 1 ? "" : "s")…"
    }

    private var historyButton: some View {
        Button {
            viewModel.isPresentingHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20.0))
                .frame(width: 44.0, height: 44.0)
        }
        .accessibilityLabel("History")
        .accessibilityIdentifier("doc-history")
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $selectedPhotos,
            maxSelectionCount: max(1, maxPendingMediaAttachments - pendingAttachments.count),
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "photo")
                .font(.system(size: 20.0))
                .frame(width: 44.0, height: 44.0)
        }
        .disabled(!viewModel.isDmReadyForDisplay || pendingAttachments.count >= maxPendingMediaAttachments)
        .accessibilityLabel("Choose screenshots")
        .accessibilityIdentifier("doc-photo-picker")
    }

    private var messageField: some View {
        TextField(
            viewModel.isDmReadyForDisplay ? "Add screenshots or tell Doc…" : "Preparing Doc…",
            text: messageText,
            axis: .vertical
        )
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        .focused($focus, equals: .message)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .frame(minHeight: 44.0)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18.0))
        .disabled(!viewModel.isDmReadyForDisplay)
        .submitLabel(.send)
        .onSubmit(send)
        .accessibilityIdentifier("doc-message-field")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32.0))
                .frame(width: 44.0, height: 44.0)
        }
        .disabled(dmViewModel?.sendButtonEnabled != true)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("doc-send")
    }

    private func send() {
        guard let dmViewModel, dmViewModel.sendButtonEnabled else { return }
        let screenshotCount = pendingPhotoCount
        dmViewModel.onSendMessage(focusCoordinator: focusCoordinator)
        viewModel.didSend(screenshotCount: screenshotCount)
    }

    private func load(_ photos: [PhotosPickerItem]) {
        guard !photos.isEmpty else { return }
        selectedPhotos = []
        Task { @MainActor in
            for photo in photos {
                guard let data = try? await photo.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    continue
                }
                dmViewModel?.addPhotoAttachment(image)
            }
        }
    }
}

private struct DocAttachmentThumbnail: View {
    let attachment: PendingMediaAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch attachment {
                case .photo(let photo):
                    Image(uiImage: photo.image)
                        .resizable()
                        .scaledToFill()
                case .video(let video):
                    if let thumbnail = video.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                case .file:
                    Image(systemName: "doc.fill")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 64.0, height: 64.0)
            .clipShape(RoundedRectangle(cornerRadius: 12.0))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7))
                    .frame(width: 44.0, height: 44.0)
            }
            .accessibilityLabel("Remove attachment")
        }
    }
}

private struct DocRoomPlaceholderView: View {
    let doc: DocStatus

    var body: some View {
        List {
            Section {
                if let url = doc.googleURL {
                    Link(destination: url) {
                        Label("Open in Google Docs", systemImage: "arrow.up.right.square")
                            .frame(minHeight: 44.0)
                    }
                }
            }
            Section("Latest change") {
                Text("\(doc.lastChange.who) \(doc.lastChange.what)")
            }
        }
        .navigationTitle(doc.name)
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("doc-room-placeholder")
    }
}
