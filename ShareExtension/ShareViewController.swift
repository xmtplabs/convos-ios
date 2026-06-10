import Combine
import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import Foundation
import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Throwaway spike compose UI for the share extension. A custom UIViewController
/// (not SLComposeServiceViewController) hosting the app's real composer
/// (MessagesBottomBar from ConvosComposer) over the same send path as the app
/// (attachments first, then text).
final class ShareViewController: UIViewController {
    private let model: ShareComposeModel = ShareComposeModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let composeView = ShareComposeView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onSend: { [weak self] in self?.complete() }
        )
        let host = UIHostingController(rootView: composeView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        model.start(extensionContext: extensionContext)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: NSUserCancelledError))
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

@MainActor
@Observable
final class ShareComposeModel {
    var targetTitle: String = "Convo"
    /// The selected target conversation, for the top-bar pill. Nil until
    /// `prepare` resolves one; `targetTitle` stays as a fallback label.
    var targetConversation: Conversation?
    var messageText: String = ""
    var pendingMediaAttachments: [PendingMediaAttachment] = []
    var isReady: Bool = false
    var isSending: Bool = false
    var messages: [MessagesListItemType] = []
    /// The sharer's profile, for the composer's avatar. Spike: a placeholder
    /// profile until the extension wires up the real profile repository.
    var profile: Profile = .mock(name: "You")

    private var client: ConvosClient?
    private var targetConversationId: String?
    private var messagesListRepository: MessagesListRepository?
    private var messagesCancellable: AnyCancellable?

    var canSend: Bool {
        let hasText: Bool = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isReady && !isSending && (!pendingMediaAttachments.isEmpty || hasText)
    }

    func start(extensionContext: NSExtensionContext?) {
        Task { await prepare(extensionContext: extensionContext) }
    }

    func appendPhoto(_ image: UIImage) {
        guard pendingMediaAttachments.count < maxPendingMediaAttachments else { return }
        pendingMediaAttachments.append(.photo(PendingPhotoAttachment(image: image)))
    }

    func removeAttachment(id: UUID) {
        pendingMediaAttachments.removeAll { $0.id == id }
    }

    private func prepare(extensionContext: NSExtensionContext?) async {
        do {
            let environment = try NotificationExtensionEnvironment.getEnvironment()
            ConvosLog.configure(environment: environment)
            ConfigManager.configure(overrides: .empty)
            DeviceInfo.configure(IOSDeviceInfo())
            ImageCompression.configure(IOSImageCompression())
            PushNotificationRegistrar.configure(IOSPushNotificationRegistrar())
            RichLinkMetadata.configure(IOSRichLinkMetadataProvider())
            if let firebaseConfigURL = ConfigManager.shared.currentEnvironment.firebaseConfigURL {
                FirebaseHelperCore.configure(
                    with: firebaseConfigURL,
                    debugToken: Secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN,
                    forceDebugProvider: true
                )
            }
            let client = ConvosClient.client(
                environment: environment,
                platformProviders: .iOSExtension,
                coreActions: NoOpCoreActions()
            )
            self.client = client

            let conversations = (try? client.session.conversationsRepository(for: [.allowed]).fetchAll()) ?? []
            let intent = extensionContext?.intent as? INSendMessageIntent
            let target = conversations.first { $0.id == intent?.conversationIdentifier } ?? conversations.first
            targetConversationId = target?.id
            targetConversation = target
            // The donated intent carries the conversation's display name
            // (Conversation.title lives in the app target, not here).
            let fallbackTitle: String? = target.map { $0.computedDisplayName(memberNameOverride: { _ in nil }) }
            targetTitle = intent?.speakableGroupName?.spokenPhrase ?? fallbackTitle ?? "Convo"

            if let target {
                startObservingMessages(for: target, client: client)
            }

            if let image = await Self.loadSharedImage(extensionContext: extensionContext) {
                appendPhoto(image)
            }
            isReady = targetConversationId != nil
        } catch {
            Log.error("prepare failed: \(error.localizedDescription)")
        }
    }

    private func startObservingMessages(for conversation: Conversation, client: ConvosClient) {
        let repository = MessagesListRepository(
            messagesRepository: client.session.messagesRepository(for: conversation.id),
            transcriptRepository: client.session.voiceMemoTranscriptRepository(),
            hiddenBundleMessagesRepository: client.session.builderBundleHiddenMessagesRepository(),
            conversationId: conversation.id,
            speechPermissionProvider: { false }
        )
        repository.currentOtherMemberCount = conversation.membersWithoutCurrent.count
        messagesListRepository = repository
        messages = (try? repository.fetchInitial()) ?? []
        messagesCancellable = repository.messagesListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.messages = items
            }
        repository.startObserving()
    }

    func send() async {
        guard let client, let targetConversationId else {
            return
        }
        isSending = true
        let text: String = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let messagingService = client.session.messagingService()
        do {
            // Attachments first, then text - matches the in-app send order.
            for attachment in pendingMediaAttachments {
                guard case .photo(let photo) = attachment else {
                    Log.warning("share extension spike sends photos only; skipping \(attachment.id)")
                    continue
                }
                let imageWriter = messagingService.messageWriter(
                    for: targetConversationId,
                    backgroundUploadManager: ForegroundUploadManager()
                )
                try await imageWriter.send(image: photo.image)
            }
            if !text.isEmpty {
                let textWriter = messagingService.messageWriter(
                    for: targetConversationId,
                    backgroundUploadManager: UnavailableBackgroundUploadManager()
                )
                try await textWriter.send(text: text)
            }
            Log.info("sent to \(targetConversationId) attachments=\(pendingMediaAttachments.count) text=\(!text.isEmpty)")
        } catch {
            Log.error("send failed: \(error.localizedDescription)")
        }
        isSending = false
    }

    private static func loadSharedImage(extensionContext: NSExtensionContext?) async -> UIImage? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let image = await loadImage(from: provider) {
                    return image
                }
            }
        }
        return nil
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                let image: UIImage?
                switch item {
                case let url as URL:
                    image = (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
                case let data as Data:
                    image = UIImage(data: data)
                case let provided as UIImage:
                    image = provided
                default:
                    image = nil
                }
                continuation.resume(returning: image)
            }
        }
    }
}

struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel
    let onCancel: () -> Void
    let onSend: () -> Void

    @FocusState private var focusState: MessagesViewInputFocus?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var voiceMemoRecorder: VoiceMemoRecorder = VoiceMemoRecorder()
    @State private var displayName: String = ""
    @State private var isPhotoPickerPresented: Bool = false

    // Local, read-mostly state backing the conversation indicator pill. The
    // extension never edits the conversation, so these only exist to satisfy
    // the indicator's bindings.
    @State private var conversationName: String = ""
    @State private var conversationImage: UIImage?
    @State private var presentingConversationSettings: Bool = false
    @State private var activeToast: IndicatorToastStyle?
    @State private var autoRevealPhotos: Bool = false
    @State private var contextMenuState: MessageContextMenuState = MessageContextMenuState()
    @State private var bottomBarHeight: CGFloat = 0.0

    var body: some View {
        NavigationStack {
            transcript
                .ignoresSafeArea()
                .safeAreaBar(edge: .bottom) {
                    composerBar
                }
                .toolbar { closeToolbarItem }
                .toolbarTitleDisplayMode(.inline)
        }
        .overlay(alignment: .top) {
            if let conversation = model.targetConversation {
                conversationIndicator(for: conversation)
                    .padding(.top, DesignConstants.Spacing.step2x)
            }
        }
        .onAppear { focusState = .message }
        .onChange(of: model.targetTitle) { _, newValue in
            conversationName = newValue
        }
        .onChange(of: focusCoordinator.currentFocus) { _, newFocus in
            focusState = newFocus
        }
        .onChange(of: focusState) { _, newFocus in
            focusCoordinator.syncFocusState(newFocus)
        }
    }

    /// App-chrome top bar: the conversation indicator pill centered (once a
    /// target conversation is resolved), with a glass-circle close button
    private func conversationIndicator(for conversation: Conversation) -> some View {
        ConversationIndicator(
            conversation: conversation,
            placeholderName: model.targetTitle,
            untitledConversationPlaceholder: model.targetTitle,
            subtitle: "Convo",
            scheduledExplosionDate: conversation.scheduledExplosionDate,
            conversationName: $conversationName,
            conversationImage: $conversationImage,
            presentingConversationSettings: $presentingConversationSettings,
            activeToast: $activeToast,
            autoRevealPhotos: $autoRevealPhotos,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            showsExplodeNowButton: false,
            explodeState: .ready,
            onConversationInfoTapped: {},
            onConversationInfoLongPressed: {},
            onConversationNameEndedEditing: {},
            onConversationSettings: {},
            onExplodeNow: {},
            infoView: { EmptyView() },
            quickEditView: { _, _ in EmptyView() }
        )
    }

    @ToolbarContentBuilder
    private var closeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(role: .close, action: onCancel)
                .accessibilityIdentifier("share-cancel-button")
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = model.targetConversation {
            MessagesViewRepresentable(
                conversation: conversation,
                messages: model.messages,
                invite: .empty,
                onUserInteraction: {},
                hasLoadedAllMessages: true,
                shouldBlurPhotos: false,
                focusCoordinator: focusCoordinator,
                onTapAvatar: { _ in },
                onLoadPreviousMessages: {},
                onTapInvite: { _ in },
                onReaction: { _, _ in },
                onToggleReaction: { _, _ in },
                onTapReactions: { _ in },
                onTapReadReceipts: { _ in },
                onTapThinkingIndicator: { _ in },
                onReply: { _ in },
                contextMenuState: contextMenuState,
                onPhotoRevealed: { _ in },
                onPhotoHidden: { _ in },
                onPhotoDimensionsLoaded: { _, _, _ in },
                onAgentOutOfCredits: {},
                creditsDepleted: false,
                onTapUpdateMember: { _ in },
                onRetryMessage: { _ in },
                onDeleteMessage: { _ in },
                onRetryAgentJoin: {},
                onCopyInviteLink: {},
                onConvoCode: {},
                onInviteAgent: {},
                onRetryTranscript: { _ in },
                profileSheetForMember: { _ in AnyView(EmptyView()) },
                memberContactOverride: { _ in nil },
                isAgentJoinPending: false,
                headerMode: .suppressed,
                bottomBarHeight: bottomBarHeight,
                hasBottomBar: true,
                scrollToBottomTrigger: { _ in },
                messageInputFocusTrigger: { _ in }
            )
        } else {
            Spacer(minLength: 0)
        }
    }

    private var composerBar: some View {
        let handleSend = {
            Task { @MainActor in
                await model.send()
                onSend()
            }
        }
        return MessagesBottomBar(
            profile: model.profile,
            displayName: $displayName,
            messageText: $model.messageText,
            pendingMediaAttachments: model.pendingMediaAttachments,
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: model.canSend,
            profileImage: .constant(nil),
            isPhotoPickerPresented: $isPhotoPickerPresented,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            isSettingUpProfile: false,
            animateAvatarForProfileSetup: false,
            canEditProfile: false,
            pinsExpandedInput: true,
            messagesTextFieldEnabled: model.isReady,
            onProfilePhotoTap: {},
            onSendMessage: { _ = handleSend() },
            onClearInvite: {},
            onClearLinkPreview: {},
            onClearMediaAttachment: { id in model.removeAttachment(id: id) },
            onDisplayNameEndedEditing: {},
            onPhotoSelected: { image in model.appendPhoto(image) },
            onVideoSelected: { _ in Log.warning("share extension spike: video attachments not supported") },
            onFileSelected: { _, _, _, _ in Log.warning("share extension spike: file attachments not supported") },
            onProfileSettings: {},
            onVoiceMemoTap: {},
            voiceMemoRecorder: voiceMemoRecorder,
            onSendVoiceMemo: {},
            onConvosAction: {},
            onBaseHeightChanged: { height in
                bottomBarHeight = height
            },
            bottomBarContent: { EmptyView() },
            quickEditView: { _, _ in EmptyView() },
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() }
        )
    }
}
