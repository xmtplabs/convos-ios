import Combine
import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import Foundation
import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Process-scoped bootstrap for the share extension. iOS reuses extension
/// processes across share-sheet presentations; building a second ConvosClient
/// (or a second background session under the same identifier) in a reused
/// process stalls the publish pipeline behind the first instance's still-open
/// resources - observed as a publish that times out its whole runway on the
/// second share from one process.
@MainActor
final class ExtensionRuntime {
    let client: ConvosClient
    let uploadManager: BackgroundUploadManager

    private static var cached: ExtensionRuntime?

    static func shared() throws -> ExtensionRuntime {
        if let cached {
            Log.info("extension runtime reused")
            return cached
        }
        let runtime = try ExtensionRuntime()
        cached = runtime
        return runtime
    }

    private init() throws {
        let environment = try NotificationExtensionEnvironment.getEnvironment()
        ConvosLog.configure(environment: environment)
        Log.info("extension runtime boot")
        ConfigManager.configure(overrides: .empty)
        // Prefer the App Check token the main app mirrored into the app
        // group: the extension can't App Attest, and archive builds (PR
        // preview, TestFlight) carry no pinned debug token, so its own
        // attestation only works in local developer builds.
        FirebaseHelperCore.sharedTokenAppGroupIdentifier = environment.appGroupIdentifier
        // Memory flags (BoundedImageDecode cap, constrained image cache) are
        // set in ShareViewController.viewDidLoad, before the first render
        // can construct the cache singleton.
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
        uploadManager = BackgroundUploadManager(
            sessionIdentifier: BackgroundUploadManager.shareExtensionSessionIdentifier,
            sharedContainerIdentifier: environment.appGroupIdentifier
        )
        client = ConvosClient.client(
            environment: environment,
            platformProviders: .iOSExtension,
            coreActions: NoOpCoreActions()
        )
    }
}

/// Throwaway spike compose UI for the share extension. A custom UIViewController
/// (not SLComposeServiceViewController) hosting the app's real composer
/// (MessagesBottomBar from ConvosComposer) over the same send path as the app
/// (attachments first, then text).
final class ShareViewController: UIViewController {
    private let model: ShareComposeModel = ShareComposeModel()

    /// Number of share sheets currently alive in this process. Guards
    /// process retirement: iOS can hand a new share to this process while a
    /// previous share's publish runway is still winding down.
    @MainActor static var activeSheetCount: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.activeSheetCount += 1
        ComposerHostContext.isAppExtension = true
        // Before any view renders: the first avatar to draw constructs the
        // ImageCache singleton, which reads these at init. Setting them in
        // the async prepare path races that first render and can lock in the
        // main app's 300 MB cache budget and 2048px decodes.
        ImageCacheContainer.isMemoryConstrainedProcess = true
        BoundedImageDecode.processMaxPixelSize = 512
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
        Self.activeSheetCount -= 1
        ConvosLog.flush()
        extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: NSUserCancelledError))
        ExtensionProcessRetirement.retireIfIdle(after: Constant.retireAfterCancelDelay, reason: "cancelled")
    }

    private func complete() {
        Self.activeSheetCount -= 1
        // completeRequest terminates the process; without a flush the tail of
        // the send's log lines never reaches the shared log file.
        ConvosLog.flush()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        // Fallback retirement for completions that hold no publish runway
        // (nothing staged); runway paths retire the moment the runway ends.
        ExtensionProcessRetirement.retireIfIdle(after: Constant.retireFallbackDelay, reason: "completed")
    }

    private enum Constant {
        /// Long enough for the host's dismissal animation and any lingering
        /// XPC teardown after a cancel.
        static let retireAfterCancelDelay: TimeInterval = 2.0
        /// Past the opportunistic publish window and the expiring-activity
        /// runway, so this only fires when the real signal never came.
        static let retireFallbackDelay: TimeInterval = 35.0
    }
}

/// iOS reuses share-extension processes, and each completed share leaves
/// ~15 MB of client residue behind (observed baselines: 14 MB fresh, 58 MB
/// after two shares against the 120 MB jetsam ceiling - the third share in
/// one process died during photo load, before the user could even commit).
/// Exiting once all work is done trades warm relaunch for a fresh 14 MB
/// process on every share; the staged outbox already guarantees delivery of
/// anything a dead process left behind, so exit is safe by construction.
/// Lock-protected once-only latch; `fire()` returns true for exactly one
/// caller across threads.
final class OneShotFlag: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var fired: Bool = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

enum ExtensionProcessRetirement {
    /// In-flight publish runways. Sheets and runways have different
    /// lifetimes - a runway outlives its dismissed sheet - so retirement
    /// must wait for both counts to reach zero, or one share's retirement
    /// could kill another share's still-publishing runway (overlapping
    /// shares in one reused process). Lock-protected because runways run
    /// on background queues.
    private static let lock: NSLock = NSLock()
    nonisolated(unsafe) private static var runwayCount: Int = 0

    static nonisolated func runwayBegan() {
        lock.lock()
        runwayCount += 1
        lock.unlock()
    }

    static nonisolated func runwayEnded() {
        lock.lock()
        runwayCount -= 1
        lock.unlock()
    }

    private static nonisolated var activeRunways: Int {
        lock.lock()
        defer { lock.unlock() }
        return runwayCount
    }

    /// Exits the process if no sheet is active and no runway is publishing
    /// after `delay`. A share or runway that begins in the window flips its
    /// count and the exit is skipped; whichever activity finishes last
    /// schedules the retirement that actually fires.
    static nonisolated func retireIfIdle(after delay: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard ShareViewController.activeSheetCount == 0, activeRunways == 0 else { return }
            Log.info("retiring extension process (\(reason))")
            ConvosLog.flush()
            exit(0)
        }
    }
}

@MainActor
@Observable
final class ShareComposeModel: AgentDraftComposing {
    var targetTitle: String = "Convo"
    /// The selected target conversation, for the top-bar pill. Nil until
    /// `prepare` resolves one; `targetTitle` stays as a fallback label.
    var targetConversation: Conversation?
    var messageText: String = ""
    var pendingMediaAttachments: [PendingMediaAttachment] = []
    /// A shared URL rendered as the composer's link-preview chip (mirrors the
    /// in-app pasted-link flow); sent as its own message ahead of typed text.
    var pendingLinkPreview: LinkPreview?
    /// True when the share carried no donated conversation target and the
    /// user chose "Make an agent" from the picker: the sheet hosts the
    /// agent builder and Make finishes the agent in place.
    var isNewAgentTarget: Bool = false
    /// True while the targetless share shows the conversation picker (all
    /// of the user's conversations plus the Make-an-agent action row).
    /// Cleared when the user picks a conversation or the agent builder.
    var isPickingTarget: Bool = false
    /// The pickable conversations, in the same order the app's chats list
    /// shows them.
    var pickerConversations: [Conversation] = []
    /// Set after a successful Make: the sheet morphs into the new
    /// conversation's transcript with the agent-join progress cell,
    /// mirroring the app's post-Make reveal, for a beat before it closes.
    var didMakeAgent: Bool = false
    /// The pre-created (still hidden) draft conversation, resolved as soon
    /// as `prepareDraftConversation` finishes so the transcript can mount
    /// beneath the draft composer ahead of Make.
    var draftConversation: Conversation?
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
    /// Pre-creates the hidden draft conversation while the user composes,
    /// the way the in-app builder does, so Make itself is instant instead
    /// of freezing the sheet on a network round-trip. Kicked off as soon as
    /// the share resolves to the New Agent target.
    private var draftConversationTask: Task<AgentCreationFlow.PreparedConversation, Error>?

    var canSend: Bool {
        let hasText: Bool = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isReady && !isSending && (!pendingMediaAttachments.isEmpty || hasText || pendingLinkPreview != nil)
    }

    // MARK: AgentDraftComposing (the New Agent draft surface)

    var composerTextBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.messageText ?? "" },
            set: { [weak self] in self?.messageText = $0 }
        )
    }
    var isRecordingVoiceMemo: Bool { false }
    var recordedVoiceMemo: (url: URL, duration: TimeInterval)? { nil }
    var voiceMemoAudioLevels: [Float] { [] }
    let voiceMemoRecorder: VoiceMemoRecorder = VoiceMemoRecorder()
    var isMakeEnabled: Bool { canSend }
    var isCommitting: Bool { isSending }
    /// The extension's Info.plist carries no microphone usage description.
    var supportsVoiceMemo: Bool { false }
    /// The agent-builder handoff stages photos only.
    var allowsVideoAttachments: Bool { false }

    func addVideoAttachment(url: URL) {
        Log.warning("agent-builder share stages photos only; ignoring video")
    }

    func addFileAttachment(url: URL, filename: String, mimeType: String, fileSize: Int) {
        Log.warning("agent-builder share stages photos only; ignoring file \(filename)")
    }

    func cancelRecordedVoiceMemo() {}
    func startVoiceMemoRecording(restoreComposerFocusAfter: Bool) {}

    func start(extensionContext: NSExtensionContext?) {
        Task { await prepare(extensionContext: extensionContext) }
    }

    func appendPhoto(_ image: UIImage) {
        guard pendingMediaAttachments.count < maxPendingMediaAttachments else { return }
        pendingMediaAttachments.append(.photo(PendingPhotoAttachment(image: image)))
    }

    func addPhotoAttachment(_ image: UIImage) {
        appendPhoto(image)
    }

    func removeAttachment(id: UUID) {
        pendingMediaAttachments.removeAll { $0.id == id }
    }

    private func prepare(extensionContext: NSExtensionContext?) async {
        do {
            let runtime = try ExtensionRuntime.shared()
            let client = runtime.client
            self.client = client
            uploadManager = runtime.uploadManager

            // A database read failure is not "no convos" - surface it as the
            // bootstrap error it is instead of a misleading empty state.
            let conversations = try client.session.conversationsRepository(for: [.allowed]).fetchAll()
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
                // No donated target: show the conversation picker. The user
                // either sends into an existing conversation or taps the
                // Make-an-agent row, which swaps the sheet to the builder.
                target = nil
                isPickingTarget = true
                pickerConversations = conversations
            }
            targetConversationId = target?.id
            targetConversation = target
            // The donated intent carries the conversation's display name
            // (Conversation.title lives in the app target, not here).
            let fallbackTitle: String? = target.map { $0.computedDisplayName(memberNameOverride: { _ in nil }) }
            targetTitle = intent?.speakableGroupName?.spokenPhrase ?? fallbackTitle ?? (isNewAgentTarget ? "New Agent" : "Convo")

            if let target {
                if let myProfile = target.members.first(where: { $0.isCurrentUser })?.profile {
                    profile = myProfile
                }
                startObservingMessages(for: target, client: client)
            }

            let images = await Self.loadSharedImages(extensionContext: extensionContext, limit: Constant.maxSharedImages)
            for image in images {
                appendPhoto(image)
            }
            if !images.isEmpty {
                Log.info("shared images loaded count=\(images.count)")
            }
            if messageText.isEmpty, let sharedText = await Self.loadSharedText(extensionContext: extensionContext) {
                // A shared URL (Safari etc.) becomes the composer's
                // link-preview chip, matching the in-app pasted-link flow;
                // anything that doesn't parse as a link stays typed text.
                if let preview = LinkPreview.from(text: sharedText) {
                    pendingLinkPreview = preview
                    Log.info("shared link parsed: \(preview.url)")
                } else {
                    messageText = sharedText
                    Log.info("shared text loaded (no link parsed): \(sharedText.count) chars")
                }
            }
            isReady = targetConversationId != nil || isNewAgentTarget || isPickingTarget
        } catch {
            Log.error("prepare failed: \(error.localizedDescription)")
            unavailableReason = "Convos could not start. Try again."
        }
    }

    private func publishPromptInBackground(_ created: AgentCreationFlow.CreatedAgent, session: any SessionManagerProtocol) {
        guard created.commit.promptMessageId != nil else { return }
        ExtensionProcessRetirement.runwayBegan()
        Task {
            do {
                try await AgentCreationFlow.sendPrompt(
                    for: created,
                    session: session,
                    backgroundUploadManager: UnavailableBackgroundUploadManager()
                )
                Log.info("prompt published to \(created.conversationId)")
            } catch {
                Log.error("prompt publish failed; the app's drain will republish: \(error.localizedDescription)")
            }
            ExtensionProcessRetirement.runwayEnded()
            ExtensionProcessRetirement.retireIfIdle(after: 1.0, reason: "prompt published")
        }
    }

    /// Picker row tap: the share becomes a normal conversation-target
    /// compose, identical to arriving via a donated share-sheet suggestion.
    func selectShareTarget(_ conversation: Conversation) {
        guard let client else { return }
        isPickingTarget = false
        targetConversationId = conversation.id
        targetConversation = conversation
        targetTitle = conversation.computedDisplayName(memberNameOverride: { _ in nil })
        if let myProfile = conversation.members.first(where: { $0.isCurrentUser })?.profile {
            profile = myProfile
        }
        startObservingMessages(for: conversation, client: client)
    }

    /// Make-an-agent row tap: swap the sheet to the agent builder with the
    /// shared attachments already staged in the composer, and start
    /// pre-creating the hidden draft conversation so Make is instant.
    /// Creation starts here - not at sheet open - so shares that target an
    /// existing conversation never mint an unused row.
    func chooseMakeAgent() {
        guard let client else { return }
        isPickingTarget = false
        isNewAgentTarget = true
        targetTitle = "New Agent"
        let session = client.session
        draftConversationTask = Task { [weak self] in
            let draft = try await AgentCreationFlow.prepareDraftConversation(session: session)
            Log.info("draft conversation ready \(draft.conversationId)")
            // Mount the transcript now, hidden beneath the draft composer,
            // so the collection view's expensive first layout is long done
            // when Make crossfades to it.
            await self?.mountDraftTranscript(id: draft.conversationId, client: client)
            return draft
        }
    }

    private func mountDraftTranscript(id conversationId: String, client: ConvosClient) {
        guard let conversation = try? client.session.conversationRepository(for: conversationId).fetchConversation() else {
            Log.warning("draft conversation \(conversationId) not readable; transcript mounts at reveal instead")
            return
        }
        draftConversation = conversation
        startObservingMessages(for: conversation, client: client)
    }

    /// Swaps the draft composer for the new conversation's transcript so the
    /// user sees the same post-Make surface the app shows: the creation-
    /// prompt card (seeded synchronously, like the app's inner view model),
    /// the "activating agent" progress card, and the prompt message.
    private func revealCreatedConversation(
        _ created: AgentCreationFlow.CreatedAgent,
        client: ConvosClient,
        commitStartedAt: Date
    ) async {
        guard let conversation = try? client.session.conversationRepository(for: created.conversationId).fetchConversation() else {
            Log.warning("make agent: created conversation \(created.conversationId) not readable for reveal; closing without transcript")
            return
        }
        if let myProfile = conversation.members.first(where: { $0.isCurrentUser })?.profile {
            profile = myProfile
        }
        targetConversationId = conversation.id
        targetConversation = conversation
        targetTitle = conversation.computedDisplayName(memberNameOverride: { _ in nil })
        // Pre-mounted at draft-ready in the common path; the fallback
        // (create-at-Make) still mounts here.
        if messagesListRepository == nil {
            startObservingMessages(for: conversation, client: client)
        }
        // Seed the cards the app's view model would provide: the processor
        // renders the creation card from the summary without waiting for the
        // prompt row to land, and the activating card supplies the join
        // progress the user watches in-app. The generation has only just
        // been submitted, so `.preparing` is the honest phase for the few
        // seconds this sheet stays up.
        messagesListRepository?.agentBuilderSummary = created.commit.summary
        messagesListRepository?.agentActivating = AgentActivatingCardContent(
            id: conversation.id,
            phase: .preparing,
            agentName: nil,
            emoji: nil,
            agentDescription: nil,
            progressPhrases: []
        )
        // Phase A parity with the app: the composer content gets its full
        // 180ms fade (driven by isCommitting) before the reveal spring
        // starts, even when the local commit finishes faster.
        let elapsed = Date().timeIntervalSince(commitStartedAt)
        let remaining = Constant.contentFadeSeconds - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            didMakeAgent = true
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
        // Cap the transcript: every photo bubble decodes its image into
        // memory, and a long history of media messages pushes the extension's
        // baseline toward the 120 MB jetsam ceiling before a send even starts.
        messages = Array(((try? repository.fetchInitial()) ?? []).suffix(Constant.transcriptMessageLimit))
        messagesCancellable = repository.messagesListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.messages = Array(items.suffix(Constant.transcriptMessageLimit))
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
        guard !isSending, let client else {
            return false
        }
        isSending = true
        defer { isSending = false }
        sendError = nil
        let text: String = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentCount = pendingMediaAttachments.count
        Log.info("send(): raw=\(messageText.count) trimmed=\(text.count) chars, attachments=\(attachmentCount) link=\(pendingLinkPreview != nil) newAgent=\(isNewAgentTarget)")
        if isNewAgentTarget {
            return await makeAgent(text: text, client: client)
        }
        guard let targetConversationId else {
            return false
        }
        let messagingService = client.session.messagingService()
        // One writer for the whole send: its queue publishes strictly in
        // order, so the text always reaches the network after the photos.
        // Separate writers would race their independent queues and a fast
        // text publish could arrive before a slow photo upload.
        let writer = messagingService.messageWriter(
            for: targetConversationId,
            backgroundUploadManager: uploadManager ?? ForegroundUploadManager()
        )
        var stagedCount = 0
        do {
            // Attachments first, then text - matches the in-app send order.
            for attachment in pendingMediaAttachments {
                guard case .photo(let photo) = attachment else {
                    Log.warning("share extension spike sends photos only; skipping \(attachment.id)")
                    continue
                }
                try await writer.send(image: photo.image)
                stagedCount += 1
                // Drop each attachment as it stages: if a later item fails
                // and the user retries, already-staged photos must not be
                // staged and published a second time.
                pendingMediaAttachments.removeAll { $0.id == attachment.id }
            }
            // Link before typed text, matching the in-app send order.
            if let linkURL = pendingLinkPreview?.url {
                try await writer.send(text: linkURL)
                stagedCount += 1
                pendingLinkPreview = nil
            }
            if !text.isEmpty {
                try await writer.send(text: text)
                stagedCount += 1
            }
        } catch {
            Log.error("staging failed: \(error)")
            sendError = "Could not queue the message: \(error.localizedDescription)"
            return false
        }
        Log.info("staged to \(targetConversationId) attachments=\(attachmentCount) text=\(!text.isEmpty)")
        // Hold a system-granted expiring activity so the publish pipeline
        // (auth -> presign -> upload handoff -> publish) can keep running
        // after the sheet closes. Without it the process suspends before the
        // upload is even handed to the background session, and delivery
        // waits for the next app open.
        Self.holdPublishRunway(writer: writer, count: stagedCount)
        // The content is staged and the optimistic bubbles are in the
        // transcript; clear the composer so the sheet doesn't sit on stale
        // input during the publish window.
        messageText = ""
        pendingMediaAttachments = []
        await Self.waitForPublishes(from: writer, count: stagedCount, upTo: Constant.opportunisticPublishWindow)
        Log.info("closing share sheet; unfinished publishes drain on next app open")
        return true
    }

    /// Runs the agent-builder commit for a targetless share through the same
    /// `AgentCreationFlow` the in-app builder's Make uses: create the draft
    /// conversation, submit the generation (attachments ride the generation
    /// API), persist the creation-prompt card, and publish the prompt. The
    /// generation row persists to the shared database, so if this process
    /// dies mid-poll the app's session bootstrap resumes it
    /// (`resumePendingGenerations`) - delivery is guaranteed, like a photo
    /// send.
    private func makeAgent(text: String, client: ConvosClient) async -> Bool {
        let commitStartedAt = Date()
        do {
            var promptText = text
            if let linkURL = pendingLinkPreview?.url {
                promptText = promptText.isEmpty ? linkURL : "\(linkURL)\n\(promptText)"
            }
            let session = client.session
            let photos: [AgentCreationFlow.Photo] = pendingMediaAttachments.compactMap { attachment in
                guard case .photo(let photo) = attachment else { return nil }
                return AgentCreationFlow.Photo(id: photo.id, image: photo.image)
            }
            let prepared = AgentCreationFlow.prepareAttachments(photos: photos)
            // Stage durably before any network work: conversation creation is
            // the window where jetsam kills have been observed (a reused
            // extension process starts near the 120 MB ceiling), and unlike a
            // photo send nothing else records the build yet. If this process
            // dies anywhere past here, the app's foreground drain finishes
            // the build from the staged record.
            let stagedId = try AgentBuildOutbox.stage(
                prompt: promptText,
                photoJPEGs: prepared.inputs.map(\.data)
            )
            // Usually already resolved (creation started when the sheet
            // opened); nil after a pre-create failure, which falls back to
            // creating at Make like before.
            let draft = try? await draftConversationTask?.value
            Log.info("make agent: staged \(stagedId); committing (draft=\(draft?.conversationId ?? "none"))")
            let created = try await AgentCreationFlow.createAgent(
                prompt: promptText,
                prepared: prepared,
                session: session,
                preparedConversation: draft
            )
            // The persisted generation row now guarantees delivery; clear the
            // staged record so the drain cannot build a duplicate agent.
            AgentBuildOutbox.clear(id: stagedId)
            Log.info("make agent: generation submitted to \(created.conversationId) attachments=\(prepared.inputs.count)")
            messageText = ""
            pendingMediaAttachments = []
            pendingLinkPreview = nil
            // Reveal before the prompt publish: the commit above is all
            // local database work, so the crossfade starts immediately (the
            // app sequences its Make the same way). The publish is network
            // and rides a retirement-guarded background task; if the process
            // still dies mid-publish, the prepared row is republished by the
            // app's outgoing-message drain.
            await revealCreatedConversation(created, client: client, commitStartedAt: commitStartedAt)
            publishPromptInBackground(created, session: session)
            return true
        } catch {
            Log.error("make agent failed: \(error)")
            sendError = "Could not make the agent: \(error.localizedDescription)"
            return false
        }
    }

    /// Keeps the process alive past sheet dismissal on a system-granted
    /// expiring activity until the writer confirms every publish, the grace
    /// period lapses, or iOS calls time. Deliberately nonisolated: the sink
    /// runs on the writer's queue and must carry no MainActor expectation.
    private nonisolated static func holdPublishRunway(
        writer: any OutgoingMessageWriterProtocol,
        count: Int
    ) {
        guard count > 0 else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var cancellable: AnyCancellable?
        cancellable = writer.sentMessage
            .prefix(count)
            .collect(count)
            .sink { _ in
                semaphore.signal()
            }
        ExtensionProcessRetirement.runwayBegan()
        // performExpiringActivity can invoke the block a second time with
        // expired=true while the first invocation is still blocked on the
        // semaphore; both invocations run their cleanup, so the count
        // decrement must be one-shot per runway or it goes negative and a
        // later share's runway is unprotected.
        let runwayEnd = OneShotFlag()
        ProcessInfo.processInfo.performExpiringActivity(withReason: "share-extension-publish") { expired in
            guard !expired else {
                cancellable?.cancel()
                // Unblock the original invocation promptly; iOS is about to
                // suspend the process either way.
                semaphore.signal()
                if runwayEnd.fire() {
                    ExtensionProcessRetirement.runwayEnded()
                }
                return
            }
            let outcome = semaphore.wait(timeout: .now() + Constant.publishRunway)
            Log.info("publish runway ended (\(outcome == .success ? "published" : "timed out"))")
            ConvosLog.flush()
            cancellable?.cancel()
            if runwayEnd.fire() {
                ExtensionProcessRetirement.runwayEnded()
            }
            ExtensionProcessRetirement.retireIfIdle(after: 1.0, reason: "runway ended")
        }
    }

    /// Waits until the writer confirms `count` publishes, or the window
    /// elapses - whichever comes first. The window keeps the fast path fast
    /// (a publish takes about three seconds on a good connection, so most
    /// sends really deliver before the sheet closes) without ever trapping
    /// the user.
    private static func waitForPublishes(
        from writer: any OutgoingMessageWriterProtocol,
        count: Int,
        upTo window: TimeInterval
    ) async {
        guard count > 0 else { return }
        var cancellable: AnyCancellable?
        let allPublished = AsyncStream<Void> { continuation in
            // The writer emits sentMessage from its background publish queue;
            // deliver on main because this closure is implicitly
            // MainActor-isolated (declared inside a MainActor type) and the
            // runtime isolation check traps otherwise.
            cancellable = writer.sentMessage
                .prefix(count)
                .collect(count)
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

    /// Loads every shared image sequentially (bounded decodes never overlap)
    /// up to `limit` - the composer holds each decoded photo until it stages,
    /// so the cap keeps a multi-photo share inside the extension's memory
    /// budget.
    private static func loadSharedImages(extensionContext: NSExtensionContext?, limit: Int) async -> [UIImage] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }
        var images: [UIImage] = []
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard images.count < limit else {
                    Log.warning("share limited to \(limit) images; ignoring the rest")
                    return images
                }
                if let image = await loadImage(from: provider) {
                    images.append(image)
                }
            }
        }
        return images
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
    private static func downsampledImage(from data: Data, maxPixel: CGFloat = Constant.sharedImageMaxPixel) -> UIImage? {
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
        let image = UIImage(cgImage: cgImage)
        return image
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        // Ask for a file representation first: the provider writes the
        // original to disk without decoding it. loadItem can deserialize a
        // fully-decoded UIImage in-process, which for a large photo is alone
        // enough to cross the extension's 120 MB jetsam ceiling before any
        // downsampling code runs - both observed device kills died inside
        // that hand-off. The mapped read plus CGImageSource subsampling never
        // materializes the full-resolution bitmap.
        let fromFile: UIImage? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                // The URL is only valid inside this handler; map the bytes
                // now and decode from the mapping.
                guard let url,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: downsampledImage(from: data))
            }
        }
        if let fromFile {
            return fromFile
        }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                let image: UIImage?
                switch item {
                case let url as URL:
                    image = (try? Data(contentsOf: url)).flatMap { downsampledImage(from: $0) }
                case let data as Data:
                    image = downsampledImage(from: data)
                case let provided as UIImage:
                    image = downsampledProvidedImage(provided)
                default:
                    image = nil
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func downsampledProvidedImage(_ image: UIImage, maxPixel: CGFloat = Constant.sharedImageMaxPixel) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxPixel else { return image }
        let scale = maxPixel / longEdge
        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        return image.preparingThumbnail(of: target) ?? image
    }

    private enum Constant {
        static let opportunisticPublishWindow: TimeInterval = 3.0
        /// How long the expiring activity holds the process for the publish
        /// after the sheet closes. iOS may end it earlier via the expiry
        /// callback; anything unfinished drains on the next app wake/open.
        static let publishRunway: TimeInterval = 25.0
        static let transcriptMessageLimit: Int = 10
        /// Mirrors NSExtensionActivationSupportsImageWithMaxCount in
        /// Info.plist. Each pending photo holds a ~9 MB decoded bitmap until
        /// it stages; six keeps a full multi-photo share inside the 120 MB
        /// extension budget.
        static let maxSharedImages: Int = 6
        /// The send pipeline holds several simultaneous decoded copies of the
        /// shared photo (original, compression pass, cache, transcript
        /// bubble). At 2048px each copy is ~22 MB and the tap-send spike
        /// crossed the 120 MB ceiling on device; 1280px cuts every copy to
        /// ~9 MB.
        static let sharedImageMaxPixel: CGFloat = 1280
        /// Mirrors the app's `contentFadeMs`: the pause between the Make tap
        /// (composer content fading) and the overlay reveal.
        static let contentFadeSeconds: TimeInterval = 0.18
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
    @Namespace private var agentDraftNamespace: Namespace.ID

    var body: some View {
        NavigationStack {
            transcript
                .ignoresSafeArea()
                .safeAreaBar(edge: .bottom) {
                    if !model.isNewAgentTarget && !model.isPickingTarget {
                        composerBar
                    }
                }
                .toolbar { closeToolbarItem }
                .toolbarTitleDisplayMode(.inline)
        }
        .overlay(alignment: .top) {
            if let conversation = model.targetConversation {
                conversationIndicator(for: conversation)
                    .padding(.top, DesignConstants.Spacing.step2x)
            } else if model.isNewAgentTarget {
                newAgentPill
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
        if model.isPickingTarget {
            conversationPicker
        } else if model.isNewAgentTarget {
            newAgentStack
        } else if let conversation = model.targetConversation {
            conversationTranscript(for: conversation)
        } else if let reason = model.unavailableReason {
            ContentUnavailableView(reason, systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } else {
            Spacer(minLength: 0)
        }
    }

    /// Targetless-share landing surface: the Make-an-agent action row (the
    /// same `ContactsPickerActionRow` the contacts compose picker uses)
    /// above every conversation, in chats-list order. Rows mirror the
    /// contacts picker's 56pt-tile layout so the two pickers read the same.
    private var conversationPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Share to…")
                    .font(.title2.bold())
                    .foregroundStyle(DesignConstants.Colors.textPrimary)
                    .padding(.top, 72)
                    .padding(.bottom, DesignConstants.Spacing.step4x)
                let makeAgentAction = { model.chooseMakeAgent() }
                ContactsPickerActionRow(
                    icon: .asset("addAgentIcon"),
                    title: "Make an agent",
                    accessibilityIdentifier: "share-picker-make-agent",
                    action: makeAgentAction
                )
                ForEach(model.pickerConversations) { conversation in
                    conversationPickerRow(for: conversation)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func conversationPickerRow(for conversation: Conversation) -> some View {
        let title: String = conversation.computedDisplayName(memberNameOverride: { _ in nil })
        let displayTitle: String = title.isEmpty ? "Convo" : title
        let action = {
            model.selectShareTarget(conversation)
            focusState = .message
        }
        return Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ConversationAvatarView(conversation: conversation, conversationImage: nil, size: 56)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(displayTitle)
                        .font(.body)
                        .foregroundStyle(DesignConstants.Colors.textPrimary)
                        .lineLimit(1)
                    Text(conversation.membersCountString)
                        .font(.subheadline)
                        .foregroundStyle(DesignConstants.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("share-picker-conversation-\(conversation.id)")
    }

    /// The new-agent surface: the transcript of the (pre-created, hidden)
    /// conversation sits mounted beneath the draft composer, and Make
    /// crossfades the composer away to reveal it - the extension's version
    /// of the app's overlay-fade commit choreography.
    private var newAgentStack: some View {
        ZStack(alignment: .top) {
            if let conversation = model.targetConversation ?? model.draftConversation {
                conversationTranscript(for: conversation)
            }
            if !model.didMakeAgent {
                DesignConstants.Colors.backgroundRaisedSecondary
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)
            }
            if !model.didMakeAgent {
                agentDraftStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(draftRemovalTransition)
                    .zIndex(2)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: model.didMakeAgent)
    }

    /// The app's exact commit choreography (`AgentBuilderView.content`): the
    /// composer slides down, scales toward its bottom edge, and fades on the
    /// reveal spring while the backdrop layer fades separately.
    private var draftRemovalTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.85, anchor: .bottom))
        )
    }

    private func conversationTranscript(for conversation: Conversation) -> some View {
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
                isAgentJoinPending: model.didMakeAgent,
                headerMode: .suppressed,
                bottomBarHeight: bottomBarHeight,
                hasBottomBar: true,
                scrollToBottomTrigger: { _ in },
                messageInputFocusTrigger: { _ in }
            )
    }

    /// The real agent-builder draft surface (shared from ConvosComposer),
    /// hosted directly in the sheet. Make stages the content for the app,
    /// which resumes the builder flow with its full auth and runway.
    private var agentDraftStack: some View {
        VStack(spacing: 0) {
            AgentDraftComposer(
                viewModel: model,
                focusState: $focusState,
                transitionNamespace: agentDraftNamespace,
                onMakeTap: handleMakeTap
            )
            .frame(maxHeight: 375)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, 72)

            Text("Start with a pic, screenshot, or note")
                .font(.footnote)
                .foregroundStyle(DesignConstants.Colors.textSecondary)
                .padding(.top, DesignConstants.Spacing.step3x)

            Spacer(minLength: 0)
        }
        .onAppear { focusState = .agentBuilder }
    }

    private func handleMakeTap() {
        guard !model.isSending else { return }
        Task { @MainActor in
            // Drop the keyboard at the tap, while the composer content is
            // already fading via isCommitting - dismissing it during the
            // crossfade made the keyboard slide-down and its layout resize
            // fight the reveal animation.
            focusState = nil
            if await model.send() {
                if model.didMakeAgent {
                    // Dwell on the post-Make transcript (creation card + join
                    // progress) before the sheet closes, mirroring the app.
                    try? await Task.sleep(for: .seconds(Constant.postMakeDwellSeconds))
                }
                onSend()
            }
        }
    }

    private var newAgentPill: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 0) {
                Text("New Agent")
                    .font(.headline)
                    .foregroundStyle(DesignConstants.Colors.textPrimary)
                Text("Draft")
                    .font(.subheadline)
                    .foregroundStyle(DesignConstants.Colors.textSecondary)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .clipShape(.capsule)
        .glassEffect(.regular, in: .capsule)
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
            composerLinkPreview: model.pendingLinkPreview,
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
            onClearLinkPreview: { model.pendingLinkPreview = nil },
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

    private enum Constant {
        /// How long the post-Make transcript stays up before the sheet
        /// dismisses itself.
        static let postMakeDwellSeconds: TimeInterval = 3.0
    }
}
