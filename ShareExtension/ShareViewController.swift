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
        ComposerHostContext.isAppExtension = true
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
        ConvosLog.flush()
        extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: NSUserCancelledError))
    }

    private func complete() {
        // completeRequest terminates the process; without a flush the tail of
        // the send's log lines never reaches the shared log file.
        ConvosLog.flush()
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
    /// User-visible reason the share sheet cannot proceed (intent target gone,
    /// no conversations, bootstrap failure). Nil while usable.
    var unavailableReason: String?
    /// User-visible send failure; the sheet stays open so content is not lost.
    var sendError: String?
    var messages: [MessagesListItemType] = []
    /// The sharer's per-conversation profile, for the composer's avatar.
    /// Resolved from the target conversation's members; placeholder until then.
    var profile: Profile = .mock(name: "You")

    private var client: ConvosClient?
    private var targetConversationId: String?
    private var messagesListRepository: MessagesListRepository?
    private var messagesCancellable: AnyCancellable?
    /// Background-session upload manager scoped to the extension's own
    /// session identifier and the app-group container. Uploads handed to it
    /// keep running after this process dies; on completion iOS launches the
    /// containing app, which finishes the publish.
    private var uploadManager: BackgroundUploadManager?

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
            // Prefer the App Check token the main app mirrored into the app
            // group: the extension can't App Attest, and archive builds (PR
            // preview, TestFlight) carry no pinned debug token, so its own
            // attestation only works in local developer builds.
            FirebaseHelperCore.sharedTokenAppGroupIdentifier = environment.appGroupIdentifier
            uploadManager = BackgroundUploadManager(
                sessionIdentifier: BackgroundUploadManager.shareExtensionSessionIdentifier,
                sharedContainerIdentifier: environment.appGroupIdentifier
            )
            DeviceInfo.configure(IOSDeviceInfo())
            ImageCompression.configure(IOSImageCompression())
            PushNotificationRegistrar.configure(IOSPushNotificationRegistrar())
            RichLinkMetadata.configure(IOSRichLinkMetadataProvider())
            // App Attest is unavailable in app extensions, so the extension can
            // only attest with the debug provider - which must never ship in a
            // production build. Outside production, force it with the Dev token;
            // in production, skip App Check configuration entirely until the
            // main-app-vended token story lands (gated sends will fail there).
            if !environment.isProduction,
               let firebaseConfigURL = ConfigManager.shared.currentEnvironment.firebaseConfigURL {
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
            // When the share came from a donated suggestion, only that exact
            // conversation is an acceptable target - falling back to an
            // arbitrary one would send under the suggested conversation's name.
            let target: Conversation?
            if let wantedId = intent?.conversationIdentifier {
                target = conversations.first { $0.id == wantedId }
                if target == nil {
                    unavailableReason = "This convo is no longer available."
                }
            } else {
                target = conversations.first
                if target == nil {
                    unavailableReason = "No convos to share into yet."
                }
            }
            targetConversationId = target?.id
            targetConversation = target
            // The donated intent carries the conversation's display name
            // (Conversation.title lives in the app target, not here).
            let fallbackTitle: String? = target.map { $0.computedDisplayName(memberNameOverride: { _ in nil }) }
            targetTitle = intent?.speakableGroupName?.spokenPhrase ?? fallbackTitle ?? "Convo"

            if let target {
                if let myProfile = target.members.first(where: { $0.isCurrentUser })?.profile {
                    profile = myProfile
                }
                startObservingMessages(for: target, client: client)
            }

            if let image = await Self.loadSharedImage(extensionContext: extensionContext) {
                appendPhoto(image)
            }
            if messageText.isEmpty, let sharedText = await Self.loadSharedText(extensionContext: extensionContext) {
                messageText = sharedText
            }
            isReady = targetConversationId != nil
        } catch {
            Log.error("prepare failed: \(error.localizedDescription)")
            unavailableReason = "Convos could not start. Try again."
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

    /// Stages the content durably (message rows in the shared database plus
    /// the photo file in the app-group cache), then waits a bounded moment
    /// for the actual publish before letting the sheet dismiss. Staging alone
    /// is enough for delivery: whatever this process doesn't finish, the main
    /// app's foreground drain republishes from the staged rows. Returns false
    /// only when staging itself fails - the content would otherwise be lost.
    func send() async -> Bool {
        guard !isSending, let client, let targetConversationId else {
            return false
        }
        isSending = true
        defer { isSending = false }
        sendError = nil
        let text: String = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("send(): raw=\(messageText.count) trimmed=\(text.count) chars, attachments=\(pendingMediaAttachments.count)")
        let messagingService = client.session.messagingService()
        var writers: [any OutgoingMessageWriterProtocol] = []
        do {
            // Attachments first, then text - matches the in-app send order.
            for attachment in pendingMediaAttachments {
                guard case .photo(let photo) = attachment else {
                    Log.warning("share extension spike sends photos only; skipping \(attachment.id)")
                    continue
                }
                let imageWriter = messagingService.messageWriter(
                    for: targetConversationId,
                    backgroundUploadManager: uploadManager ?? ForegroundUploadManager()
                )
                try await imageWriter.send(image: photo.image)
                writers.append(imageWriter)
            }
            if !text.isEmpty {
                let textWriter = messagingService.messageWriter(
                    for: targetConversationId,
                    backgroundUploadManager: UnavailableBackgroundUploadManager()
                )
                try await textWriter.send(text: text)
                writers.append(textWriter)
            }
        } catch {
            Log.error("staging failed: \(error)")
            sendError = "Could not queue the message: \(error.localizedDescription)"
            return false
        }
        Log.info("staged to \(targetConversationId) attachments=\(pendingMediaAttachments.count) text=\(!text.isEmpty)")
        // The content is staged and the optimistic bubbles are in the
        // transcript; clear the composer so the sheet doesn't sit on stale
        // input during the publish window.
        messageText = ""
        pendingMediaAttachments = []
        await Self.waitForPublishes(from: writers, upTo: Constant.opportunisticPublishWindow)
        Log.info("closing share sheet; unfinished publishes drain on next app open")
        return true
    }

    /// Waits until every writer confirms its publish, or the window elapses -
    /// whichever comes first. The window keeps the fast path fast (a publish
    /// takes about three seconds on a good connection, so most sends really
    /// deliver before the sheet closes) without ever trapping the user.
    private static func waitForPublishes(
        from writers: [any OutgoingMessageWriterProtocol],
        upTo window: TimeInterval
    ) async {
        guard !writers.isEmpty else { return }
        var cancellable: AnyCancellable?
        let allPublished = AsyncStream<Void> { continuation in
            // Writers emit sentMessage from their background publish queues;
            // deliver on main because this closure is implicitly
            // MainActor-isolated (declared inside a MainActor type) and the
            // runtime isolation check traps otherwise.
            cancellable = Publishers.MergeMany(writers.map { $0.sentMessage.first() })
                .collect(writers.count)
                .receive(on: DispatchQueue.main)
                .sink { _ in
                    continuation.yield(())
                    continuation.finish()
                }
        }
        defer { cancellable?.cancel() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in allPublished {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
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

    private static func loadSharedText(extensionContext: NSExtensionContext?) async -> String? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let urlString = await loadText(from: provider, type: .url) {
                    return urlString
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadText(from: provider, type: .plainText) {
                    return text
                }
            }
        }
        return nil
    }

    private static func loadText(from provider: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL:
                    continuation.resume(returning: url.absoluteString)
                case let text as String:
                    continuation.resume(returning: text)
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Decodes image data capped at 2048px on the long edge; a full-camera
    /// share would otherwise decode tens of megapixels inside the appex
    /// memory budget.
    private static func downsampledImage(from data: Data, maxPixel: CGFloat = 2048) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                let image: UIImage?
                switch item {
                case let url as URL:
                    image = (try? Data(contentsOf: url)).flatMap { downsampledImage(from: $0) }
                case let data as Data:
                    image = downsampledImage(from: data)
                case let provided as UIImage:
                    image = provided
                default:
                    image = nil
                }
                continuation.resume(returning: image)
            }
        }
    }

    private enum Constant {
        static let opportunisticPublishWindow: TimeInterval = 3.0
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
        .alert(
            "Couldn't send",
            isPresented: sendErrorPresented,
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.sendError ?? "") }
        )
    }

    private var sendErrorPresented: Binding<Bool> {
        Binding(
            get: { model.sendError != nil },
            set: { presented in
                if !presented {
                    model.sendError = nil
                }
            }
        )
    }

    /// App-chrome top bar: the conversation indicator pill centered (once a
    /// target conversation is resolved), with a glass-circle close button
    private func conversationIndicator(for conversation: Conversation) -> some View {
        ConversationIndicator(
            conversation: conversation,
            placeholderName: model.targetTitle,
            untitledConversationPlaceholder: model.targetTitle,
            subtitle: conversation.membersCountString,
            scheduledExplosionDate: conversation.scheduledExplosionDate,
            conversationName: $conversationName,
            conversationImage: $conversationImage,
            presentingConversationSettings: $presentingConversationSettings,
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
        } else if let reason = model.unavailableReason {
            ContentUnavailableView(reason, systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } else {
            Spacer(minLength: 0)
        }
    }

    private var composerBar: some View {
        let handleSend = {
            guard !model.isSending else { return }
            Task { @MainActor in
                if await model.send() {
                    onSend()
                }
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
            pinsExpandedInput: true,
            messagesTextFieldEnabled: model.isReady,
            onSendMessage: handleSend,
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
