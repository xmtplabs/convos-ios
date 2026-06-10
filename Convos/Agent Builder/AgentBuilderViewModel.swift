import ConvosComposer
import Combine
import ConvosConnections
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import Foundation
import Observation
import SwiftUI
import UIKit

/// User-toggleable connections offered by the Agent Builder's connection
/// sheet. v1 surfaces Apple Health (device) and Google Calendar (cloud); the
/// grant fires post-commit once the agent has joined the conversation.
enum AgentBuilderConnection: String, CaseIterable, Identifiable {
    case appleHealth
    case googleCalendar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleHealth: return "Health"
        case .googleCalendar: return "Google Calendar"
        }
    }

    var subtitle: String {
        switch self {
        case .appleHealth: return "Shared from this device"
        case .googleCalendar: return "Share your calendar with conversation"
        }
    }

    /// Row icon shown in the connections sheet (matches the existing
    /// ConversationConnectionsSection styling — black symbol on a minimal-fill
    /// rounded square).
    var rowSymbolName: String {
        switch self {
        case .appleHealth: return "heart.fill"
        case .googleCalendar: return "calendar"
        }
    }

    /// 80×80 brand image rendered as the attachment chip in the composer.
    var chipImageName: String {
        switch self {
        case .appleHealth: return "connectionAppleHealth"
        case .googleCalendar: return "connectionGoogleCalendar"
        }
    }

    /// Composio service id for cloud connections — `nil` for device kinds.
    /// Matches the `serviceId` field on `CloudConnection` and the row id
    /// used in `ConversationConnectionsViewModel.cloudRows`.
    var cloudServiceId: String? {
        switch self {
        case .appleHealth: return nil
        case .googleCalendar: return Self.googleCalendarServiceId
        }
    }

    /// `ConnectionKind` for device-backed kinds, `nil` for cloud kinds.
    /// Used by `supportedCases` to gate device kinds behind the same
    /// allowlist (`SupportedConnections`) that the chat-side picker and
    /// `ConversationConnectionsViewModel` already respect.
    var deviceKind: ConnectionKind? {
        switch self {
        case .appleHealth: return .health
        case .googleCalendar: return nil
        }
    }

    /// Cases currently surfaced to users. Mirrors the gating in
    /// `ConversationConnectionsViewModel`: device kinds are filtered by
    /// `SupportedConnections.supportedDeviceKinds` and cloud kinds by
    /// `SupportedConnections.supportedCloudServiceIds`. v1 ships cloud-
    /// only (Google Calendar) — Apple Health is hidden until the host
    /// re-introduces it in `SupportedConnections`.
    static var supportedCases: [AgentBuilderConnection] {
        allCases.filter { connection in
            if let kind = connection.deviceKind {
                return SupportedConnections.isSupported(kind)
            }
            if let cloudServiceId = connection.cloudServiceId {
                return SupportedConnections.isSupported(cloudServiceId: cloudServiceId)
            }
            return false
        }
    }

    static let googleCalendarServiceId: String = "googlecalendar"
}

/// How the builder was entered. Drives which surface (composer text
/// field vs. voice-memo recorder) gets attention on first appear.
/// `composer` is the default - the builder appears with its text field
/// focused and the keyboard up. `voiceMemo` is the
/// `AgentBuilderBar`'s waveform-button path: the builder appears
/// without focusing the text field (so the keyboard stays down while
/// the system mic-permission prompt resolves) and the view kicks off
/// `startVoiceMemoRecording` on appear.
enum AgentBuilderEntryMode {
    case composer
    case voiceMemo
}

@MainActor
@Observable
final class AgentBuilderViewModel: Identifiable {
    let id: UUID = UUID()
    let session: any SessionManagerProtocol
    let coreActions: any CoreActions
    /// How the builder was entered. Read by `AgentBuilderView` on appear
    /// to decide whether to focus the composer (and raise the keyboard)
    /// or skip focus and start a voice-memo recording instead.
    let entryMode: AgentBuilderEntryMode

    /// Captured at init so `builtAgent` reports build duration on commit.
    @ObservationIgnored
    let buildStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    /// Non-nil when the builder targets an existing conversation (the
    /// in-chat "New Agent" context-menu entry) rather than spinning up a
    /// fresh draft group (the home-screen flow). It changes three things:
    ///   - the inner conversation uses `.existingConversation` mode, so the
    ///     builder operates on the group the user is already in
    ///   - the agent join is deferred to `commit()` ("Make") instead of
    ///     firing on `.ready`, so we only add the agent once the user
    ///     confirms by tapping Make
    ///   - `discard()` never leaves / deletes the group (there's no draft to
    ///     tear down), and no `AgentBuilderSummary` is persisted (its
    ///     cutoff would hide the existing history)
    let existingConversationId: String?

    /// `true` when this builder targets an existing conversation.
    private var targetsExistingConversation: Bool { existingConversationId != nil }

    let newConversationViewModel: NewConversationViewModel

    var composerText: String = ""

    /// Routes attachment state through the underlying conversation view
    /// model so eager upload + thumbnail generation are reused. The view
    /// reads these via SwiftUI's Observation tracking through the chain.
    var pendingMediaAttachments: [PendingMediaAttachment] {
        newConversationViewModel.conversationViewModel?.pendingMediaAttachments ?? []
    }

    /// Builder-owned voice-memo recorder. Lives directly on the
    /// AgentBuilderViewModel (rather than proxying through the inner
    /// `ConversationViewModel`) because `NewConversationViewModel` seats
    /// a placeholder inner VM synchronously and swaps it for the real
    /// one once `prepareNewConversation()` returns. A proxy would lose
    /// any recording in flight at the moment of the swap; owning the
    /// recorder here keeps it stable for the entire builder lifetime.
    /// The recorded audio file (URL) is what flows through to
    /// `sendBuilderBundle()` at commit, so post-Make path is unaffected.
    let voiceMemoRecorder: VoiceMemoRecorder = VoiceMemoRecorder()

    var isRecordingVoiceMemo: Bool {
        if case .recording = voiceMemoRecorder.state { return true }
        return false
    }

    var recordedVoiceMemo: (url: URL, duration: TimeInterval)? {
        if case let .recorded(url, duration) = voiceMemoRecorder.state { return (url, duration) }
        return nil
    }

    var voiceMemoAudioLevels: [Float] {
        voiceMemoRecorder.audioLevels
    }

    /// Connection toggles set in the connections sheet. Drives chip rendering
    /// in the attachments row pre-commit; the actual grants fan out post-Make
    /// (see `commit(focusCoordinator:)`) once the agent has joined.
    var enabledConnections: Set<AgentBuilderConnection> = []

    /// `true` while a cloud OAuth flow is in flight (e.g. tapping Google
    /// Calendar without an existing global `CloudConnection`). The sheet
    /// disables toggles while this is true so the user can't queue another
    /// OAuth on top.
    var isConnectingCloud: Bool = false

    /// Snapshot of the user's existing global cloud connections — read
    /// synchronously to decide whether toggling a row needs to kick off
    /// OAuth or can short-circuit to "enabled" directly. Refreshed via
    /// `cloudConnectionRepository.connectionsPublisher()` in `init`.
    @ObservationIgnored
    private var cloudConnections: [CloudConnection] = []
    @ObservationIgnored
    private var cloudConnectionsCancellable: AnyCancellable?

    /// `CloudConnection.id` snapshotted at the moment a connection toggle
    /// flips on — either captured from `cloudConnectionManager.connect`'s
    /// return value on the OAuth path, or read out of `cloudConnections`
    /// for the already-globally-connected path. Used by
    /// `fireConnectionGrants` so the post-Make grant doesn't lose to the
    /// freshly-constructed `ConversationConnectionsViewModel`'s
    /// `.receive(on:.main)` hop (which leaves `cloudRows` empty for one
    /// runloop tick).
    @ObservationIgnored
    private var capturedCloudConnectionIds: [AgentBuilderConnection: String] = [:]

    @ObservationIgnored
    private var agentJoinTask: Task<Void, Never>?
    @ObservationIgnored
    private var didRequestAgentJoin: Bool = false
    @ObservationIgnored
    private(set) var didDiscard: Bool = false
    /// Whether the composer text field was focused at the moment the user
    /// kicked off a voice memo. Read by the stop-recording action so we can
    /// return the keyboard to the composer where the user left off.
    @ObservationIgnored
    private var restoreComposerFocusAfterRecording: Bool = false

    /// Attachments captured before the inner `ConversationViewModel`
    /// finishes its placeholder-to-real swap. Drained into the real
    /// inner VM from `onReachedReady`.
    @ObservationIgnored
    private var queuedInitialAttachments: [QueuedInitialAttachment] = []
    @ObservationIgnored
    private var hasDrainedInitialAttachments: Bool = false

    private enum QueuedInitialAttachment {
        case photo(UIImage)
        case video(URL)
        case file(url: URL, filename: String, mimeType: String, fileSize: Int)
    }

    init(
        session: any SessionManagerProtocol,
        entryMode: AgentBuilderEntryMode = .composer,
        existingConversationId: String? = nil,
        coreActions: any CoreActions = NoOpCoreActions()
    ) {
        self.session = session
        self.coreActions = coreActions
        self.entryMode = entryMode
        self.existingConversationId = existingConversationId
        let mode: NewConversationMode = existingConversationId
            .map { .existingConversation(conversationId: $0) } ?? .newAgent
        self.newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: mode,
            coreActions: coreActions
        )
        // Suppress the contact card for the entire builder lifetime. The
        // agent may join while the user is still drafting (state machine
        // hits `.ready` → `requestAgentJoinIfNeeded` → XMTP add), in which
        // case the inner conversation view *already* has the card prepared
        // — hidden under the composer overlay. If we waited until `commit()`
        // to flip the gate, that prepared card would flash visible during
        // the morph reveal. The `suppressesContactCard` flag on
        // `NewConversationViewModel` propagates the gate across the
        // inbox-acquisition VM swap (`configureWithMessagingService`), so
        // both the placeholder VM and its real replacement stay suppressed.
        self.newConversationViewModel.suppressesContactCard = true
        self.newConversationViewModel.onReachedReady = { [weak self] in
            self?.drainInitialAttachmentsIfNeeded()
            // The home flow joins the agent the instant the draft is ready so
            // it's present by the time the user taps Make. The existing-
            // conversation flow defers the join to `commit()` so we only add
            // the agent once the user confirms by tapping Make.
            guard self?.targetsExistingConversation == false else { return }
            self?.requestAgentJoinIfNeeded()
        }
        cloudConnectionsCancellable = session.cloudConnectionRepository().connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.cloudConnections = connections.filter { $0.provider == .composio }
            }
    }

    deinit {
        agentJoinTask?.cancel()
    }

    // MARK: - Composer mutations

    /// Bar-entry attachment paths (camera capture, photo picker, file
    /// picker) call `addPhotoAttachment` etc. immediately after
    /// `onStartAgent()` returns - i.e. while `NewConversationViewModel`
    /// is still on its synchronously-created placeholder
    /// `ConversationViewModel`. Forwarding straight to the inner VM at
    /// that moment lands the attachment on the placeholder, which is
    /// then discarded when `configureWithMessagingService` swaps in the
    /// real VM. Queue any add that lands before the real-VM swap and
    /// drain into the real VM at `onReachedReady`, so the eager-upload
    /// pipeline fires on the real `cachedMessageWriter`.
    func addPhotoAttachment(_ image: UIImage) {
        if hasDrainedInitialAttachments,
           let convoVM = newConversationViewModel.conversationViewModel {
            convoVM.addPhotoAttachment(image)
        } else {
            queuedInitialAttachments.append(.photo(image))
        }
    }

    func addVideoAttachment(url: URL) {
        if hasDrainedInitialAttachments,
           let convoVM = newConversationViewModel.conversationViewModel {
            convoVM.addVideoAttachment(url: url)
        } else {
            queuedInitialAttachments.append(.video(url))
        }
    }

    func addFileAttachment(url: URL, filename: String, mimeType: String, fileSize: Int) {
        if hasDrainedInitialAttachments,
           let convoVM = newConversationViewModel.conversationViewModel {
            convoVM.addFileAttachment(
                url: url,
                filename: filename,
                mimeType: mimeType,
                fileSize: fileSize
            )
        } else {
            queuedInitialAttachments.append(
                .file(url: url, filename: filename, mimeType: mimeType, fileSize: fileSize)
            )
        }
    }

    func removeAttachment(id: UUID) {
        newConversationViewModel.conversationViewModel?.removeMediaAttachment(id: id)
    }

    /// Flush attachments queued during the placeholder window into the
    /// real inner conversation VM. Called once from `onReachedReady`;
    /// the `hasDrainedInitialAttachments` flag then lets subsequent
    /// adds short-circuit straight through.
    /// Delete temp files owned by attachments still sitting in
    /// `queuedInitialAttachments`. Called from `discard()` when the user
    /// bails before the inner VM resolves -- the queue items haven't been
    /// forwarded to the VM yet, so `cleanupPendingMediaAttachments()` on
    /// the VM doesn't see them and their `temporaryDirectory` copies would
    /// otherwise leak. Photos are in-memory `UIImage`s so they have no
    /// file to delete.
    private func cleanupQueuedInitialAttachments() {
        let queued = queuedInitialAttachments
        queuedInitialAttachments = []
        for item in queued {
            switch item {
            case .photo:
                continue
            case .video(let url):
                try? FileManager.default.removeItem(at: url)
            case .file(let url, _, _, _):
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func drainInitialAttachmentsIfNeeded() {
        guard !hasDrainedInitialAttachments else { return }
        // Flip the flag only after confirming the inner VM is available.
        // Setting it before the guard left the queue full + the flag latched
        // true when `onReachedReady` ran without a VM ever resolving --
        // subsequent `addPhotoAttachment`/etc. calls would then route to the
        // queue (their `if hasDrained, let convoVM` short-circuit fails on
        // nil VM), and the queue would never drain because the early
        // `hasDrainedInitialAttachments` guard above returns immediately.
        guard let convoVM = newConversationViewModel.conversationViewModel else { return }
        hasDrainedInitialAttachments = true
        let queued = queuedInitialAttachments
        queuedInitialAttachments = []
        for item in queued {
            switch item {
            case let .photo(image):
                convoVM.addPhotoAttachment(image)
            case let .video(url):
                convoVM.addVideoAttachment(url: url)
            case let .file(url, filename, mimeType, fileSize):
                convoVM.addFileAttachment(
                    url: url,
                    filename: filename,
                    mimeType: mimeType,
                    fileSize: fileSize
                )
            }
        }
    }

    func startVoiceMemoRecording(restoreComposerFocusAfter: Bool) {
        do {
            try voiceMemoRecorder.startRecording()
            restoreComposerFocusAfterRecording = restoreComposerFocusAfter
        } catch {
            Log.error("AgentBuilder: failed to start voice memo recording: \(error.localizedDescription)")
        }
    }

    /// Stops the active voice memo recording. Returns true if the composer
    /// text field should regain focus — i.e. it was focused when the user
    /// kicked off the recording.
    @discardableResult
    func stopVoiceMemoRecording() -> Bool {
        voiceMemoRecorder.stopRecording()
        let shouldRestore = restoreComposerFocusAfterRecording
        restoreComposerFocusAfterRecording = false
        return shouldRestore
    }

    func cancelRecordedVoiceMemo() {
        voiceMemoRecorder.cancelRecording()
    }

    /// Toggle a connection. Device kinds (Apple Health) are local-only —
    /// the actual `EnablementStore` write happens post-Make in
    /// `fireConnectionGrants`. Cloud kinds (Google Calendar) check for a
    /// pre-existing global `CloudConnection`; if absent, we kick off the
    /// OAuth flow now and only flip the toggle once it succeeds. Cancelled
    /// or failed OAuth leaves the toggle off.
    func toggleConnection(_ connection: AgentBuilderConnection) {
        if enabledConnections.contains(connection) {
            enabledConnections.remove(connection)
            capturedCloudConnectionIds.removeValue(forKey: connection)
            return
        }
        switch connection {
        case .appleHealth:
            // Device-only connection — no network or OAuth. Enable
            // immediately regardless of any in-flight cloud OAuth.
            enabledConnections.insert(connection)
        case .googleCalendar:
            // Block re-entry only on the cloud OAuth path; another OAuth
            // already in flight would race for the ASWebAuthenticationSession.
            guard !isConnectingCloud else { return }
            let serviceId: String = AgentBuilderConnection.googleCalendarServiceId
            if let existing = cloudConnections.first(where: { $0.serviceId == serviceId }) {
                capturedCloudConnectionIds[connection] = existing.id
                enabledConnections.insert(connection)
            } else {
                startCloudOAuth(for: connection)
            }
        }
    }

    func removeConnection(_ connection: AgentBuilderConnection) {
        enabledConnections.remove(connection)
        capturedCloudConnectionIds.removeValue(forKey: connection)
    }

    private func startCloudOAuth(for connection: AgentBuilderConnection) {
        guard let serviceId = connection.cloudServiceId else { return }
        isConnectingCloud = true
        let manager = session.cloudConnectionManager(callbackURLScheme: ConfigManager.shared.appUrlScheme)
        Task { @MainActor [weak self] in
            defer { self?.isConnectingCloud = false }
            do {
                let cloudConnection = try await manager.connect(serviceId: serviceId)
                self?.capturedCloudConnectionIds[connection] = cloudConnection.id
                self?.enabledConnections.insert(connection)
            } catch let oauthError as OAuthError {
                if case .cancelled = oauthError { return }
                Log.error("AgentBuilder: OAuth failed for \(serviceId): \(oauthError.localizedDescription)")
            } catch {
                Log.error("AgentBuilder: connect failed for \(serviceId): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Derived state

    /// Whitespace-/newline-only composer text isn't a prompt — the commit
    /// planner trims it away and never sends it, so Make must not treat it
    /// as content either.
    private var hasPromptText: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Make button is enabled as soon as the composer has any content.
    /// Tapping Make before the state machine reaches `.ready` is fine —
    /// the morph animates the user into `ConversationView`, which surfaces
    /// its own "Agent is joining…" state, and the message is queued
    /// via `ConversationStateMachine.sendMessage` (which already
    /// serializes against `.ready`).
    var isMakeEnabled: Bool {
        hasPromptText
            || !pendingMediaAttachments.isEmpty
            || recordedVoiceMemo != nil
            || !enabledConnections.isEmpty
    }

    /// True when the user has typed something, attached anything, or is
    /// in the middle of recording / has a recorded voice memo. The X
    /// button uses this to decide whether to confirm dismissal
    /// (Continue / Discard) or to silently discard.
    var hasContent: Bool {
        !composerText.isEmpty
            || !pendingMediaAttachments.isEmpty
            || isRecordingVoiceMemo
            || recordedVoiceMemo != nil
            || !enabledConnections.isEmpty
    }

    /// Set to true when the user taps Make. Until then the builder is in
    /// "draft" mode: the conversation indicator is non-interactive
    /// (renaming/re-imaging the draft happens *after* commit, in the
    /// post-morph `ConversationView`, not here).
    var hasCommitted: Bool = false

    /// Phase A of the Make animation: text/attachments inside the composer
    /// fade out before the rounded rect itself disappears. Set true at the
    /// moment of Make tap, true through the rest of the commit (so the
    /// content stays hidden if the user re-enters the view somehow).
    var isCommitting: Bool = false

    // MARK: - Commit

    /// Tap-Make handler. Drives the staged commit animation:
    /// - Phase A (immediately): `isCommitting = true` so the composer's
    ///   content (text, attachments) fades out inside the rounded rect.
    /// - Phase B (after `Constant.contentFadeMs`): `hasCommitted = true`
    ///   so the overlay (rect + backdrop) fades and the underlying
    ///   `ConversationView` is revealed.
    ///
    /// At Phase A the composer text is copied into the inner conversation
    /// VM's `messageText` and `onSendMessage(...)` fires — that path also
    /// dispatches any pending media attachments (the picker / camera have
    /// already staged them onto the inner VM's `pendingMediaAttachments`).
    /// If the state machine hasn't reached `.ready`, the existing message-
    /// stream queue inside `ConversationStateMachine.sendMessage` holds
    /// each message until it does, so this never blocks the UI.
    func commit(focusCoordinator: FocusCoordinator) {
        guard !hasCommitted, !isCommitting else { return }

        // For the in-chat builder, `commitToExistingConversation` bails when
        // the inner conversation VM hasn't resolved yet. Mirror that check
        // upfront so we don't clear the composer or emit a success metric
        // for a commit that's about to roll back.
        if targetsExistingConversation, newConversationViewModel.conversationViewModel == nil {
            Log.warning("AgentBuilder(existing): commit attempted before inner conversation ready; leaving composer intact")
            return
        }

        isCommitting = true

        let textToSend = composerText
        composerText = ""
        emitBuiltAgentMetric(text: textToSend, isSuccess: true)

        if targetsExistingConversation {
            commitToExistingConversation(text: textToSend)
            return
        }

        if let innerVM = newConversationViewModel.conversationViewModel {
            let voiceMemoSnapshot: BuilderVoiceMemoSnapshot?
            if let recorded = recordedVoiceMemo {
                voiceMemoSnapshot = BuilderVoiceMemoSnapshot(
                    url: recorded.url,
                    duration: recorded.duration,
                    levels: voiceMemoAudioLevels
                )
            } else {
                voiceMemoSnapshot = nil
            }

            var cloudConnectionIdsByRawValue: [String: String] = [:]
            for (connection, cloudConnectionId) in capturedCloudConnectionIds {
                cloudConnectionIdsByRawValue[connection.rawValue] = cloudConnectionId
            }
            // `AgentBuilderCommitPlanner` allocates the bundle's
            // `clientMessageId`s and assembles the summary so they land in
            // `AgentBuilderSummary.bundledMessageIds` before the writer ever
            // touches the DB. `MessagesListProcessor` then filters by id, not
            // by timestamp — a slow multi-remote upload can no longer leak a
            // bare bundle bubble past the summary card.
            let attachments: [AgentBuilderSummaryAttachment] = buildSummaryAttachments(
                voiceMemo: voiceMemoSnapshot,
                mediaAttachments: innerVM.pendingMediaAttachments,
                connections: enabledConnections
            )
            let plan: AgentBuilderCommitPlan = AgentBuilderCommitPlanner.makePlan(
                prompt: textToSend,
                attachments: attachments,
                cloudConnectionIds: cloudConnectionIdsByRawValue
            )
            let textMessageId: String? = plan.textMessageId
            let bundleMessageId: String? = plan.bundleMessageId
            innerVM.agentBuilderSummary = plan.summary
            // Hide the staged-chip strip on the chat composer for the
            // duration of the post-commit upload + publish window. Without
            // this the chat view emerges (under the fading-out builder)
            // still showing the pre-Make staging chips until
            // `sendBuilderBundle` clears `pendingMediaAttachments`. The
            // flag is reset inside `sendBuilderBundle`'s defer.
            innerVM.isAwaitingBuilderBundleSend = true
            // Note: `innerVM.allowsContactCard` was already set to `false`
            // when this builder VM was constructed. The scheduled task below
            // flips it back to `true` once the chat has had time to settle
            // after the morph, so the card animates in fresh.
            //
            // Defer the sends until every pending eager photo/video upload
            // has finished, then ship the whole builder payload to the
            // agent as a synchronized burst: every media item — voice
            // memo + photos + videos + files — bundled into a single
            // `MultiRemoteAttachment` message, followed by the prompt text
            // as one XMTP message. `sendBuilderBundle` `await`s the bundle
            // send before the text send, so the agent resolves
            // attachment references before processing the prompt. The UI
            // commit (composer fade, contact-card reveal timer) runs
            // synchronously below regardless — the contact card's pulsing
            // subtitle is the user-facing loading indicator. The normal
            // conversation send path stays per-attachment so per-item
            // reactions / replies keep working there; the bundle path is
            // builder-only.
            let summaryToPersist: AgentBuilderSummary = plan.summary
            let conversationIdForPersist: String = innerVM.conversation.id
            let sessionForPersist = session
            Task { @MainActor [weak innerVM, voiceMemoSnapshot, textMessageId, bundleMessageId, summaryToPersist, conversationIdForPersist, sessionForPersist] in
                guard let innerVM else { return }
                // Persist the summary (with its `bundledMessageIds`) before
                // any writer call. If the app dies between Make and the
                // bundle landing, the filter set is already on disk — the
                // next launch's `summaryPublisher` rehydrates the summary
                // and the bundle messages are caught the moment GRDB
                // emits them. Without this ordering, a force-quit in the
                // window would leave bundle bubbles rendering bare under
                // no summary card.
                do {
                    try await sessionForPersist.agentBuilderSummaryWriter()
                        .save(summaryToPersist, for: conversationIdForPersist)
                } catch {
                    Log.error("AgentBuilder: failed to persist summary for \(conversationIdForPersist): \(error.localizedDescription)")
                }
                do {
                    try await innerVM.awaitPendingMediaUploads()
                } catch {
                    Log.error("AgentBuilder: pending media upload await failed: \(error.localizedDescription)")
                    // Fall through and attempt the bundle anyway — partial
                    // failures surface inside `sendBuilderBundle` and we'd
                    // rather try to deliver than leave the user with a
                    // stuck pulsing card.
                }
                await innerVM.sendBuilderBundle(
                    text: summaryToPersist.prompt,
                    voiceMemo: voiceMemoSnapshot,
                    textMessageId: textMessageId,
                    bundleMessageId: bundleMessageId
                )
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Constant.contentFadeMs))
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                self.hasCommitted = true
            }
            // Promote the hidden conversation row into a visible one
            // AFTER `hasCommitted` flips. The `.onChange(of: hasCommitted)`
            // inside `AgentBuilderView` fires the `onCommitted` callback,
            // which the inline-builder host (`ConversationsView`) uses to
            // present the committed conversation as a sheet. If we flip
            // `isUnused = false` first, the chats list becomes non-empty,
            // `isEmptyCTAActive` flips, the inline builder unmounts, and
            // the onChange handler never fires — leaving no sheet.
            // Sequencing the commit AFTER the state change keeps the
            // host's callback intact, then the visibility flip arrives once
            // the sheet is already on its way up. Covers both the cache-
            // claimed row and the cache-miss auto-created row (queued until
            // `.ready` if creation is still in flight).
            await self.newConversationViewModel.commitConversationVisibility()
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Constant.contactCardRevealDelayMs))
            guard let self else { return }
            // Clear both gates: the wrapper so any future VM swap also lands
            // unsuppressed, and the current VM so the card actually reveals.
            self.newConversationViewModel.suppressesContactCard = false
            self.newConversationViewModel.conversationViewModel?.allowsContactCard = true
        }
        // Connection grants are now driven by
        // `AgentBuilderConnectionGrantReplayer`, which observes the
        // persisted summary + member rows and fires grants once the
        // verified agent appears. The replayer survives app death
        // between Make and agent-join — the in-memory poll-and-timeout
        // path it replaced did not.
    }

    /// Commit path for the in-chat "New Agent" entry. The builder targets the
    /// conversation the user is already in, so there's no draft to promote.
    /// We persist an `AgentBuilderSummary` so the chat the user returns to
    /// renders the builder card immediately, but with `cutoffDate = .distantPast`
    /// so it hides none of the conversation's existing history: the brief is
    /// hidden purely by id (the `BuilderBundleManifest` for other members, the
    /// writer's local hidden rows for this client), which is robust enough that
    /// the date cutoff isn't needed here. The agent join is deferred to here
    /// (not `.ready`) so we only add the agent once the user taps Make.
    private func commitToExistingConversation(text: String) {
        guard let innerVM = newConversationViewModel.conversationViewModel else {
            // The inner conversation hasn't resolved yet. Roll back the commit
            // so the brief the user typed isn't silently lost -- restore the
            // composer text and let them tap Make again once it's ready.
            Log.warning("AgentBuilder(existing): commit before inner conversation ready; restoring composer")
            composerText = text
            isCommitting = false
            return
        }
        let voiceMemoSnapshot: BuilderVoiceMemoSnapshot?
        if let recorded = recordedVoiceMemo {
            voiceMemoSnapshot = BuilderVoiceMemoSnapshot(
                url: recorded.url,
                duration: recorded.duration,
                levels: voiceMemoAudioLevels
            )
        } else {
            voiceMemoSnapshot = nil
        }

        var cloudConnectionIdsByRawValue: [String: String] = [:]
        for (connection, cloudConnectionId) in capturedCloudConnectionIds {
            cloudConnectionIdsByRawValue[connection.rawValue] = cloudConnectionId
        }
        let attachments: [AgentBuilderSummaryAttachment] = buildSummaryAttachments(
            voiceMemo: voiceMemoSnapshot,
            mediaAttachments: innerVM.pendingMediaAttachments,
            connections: enabledConnections
        )
        // `existingConversation: true` keeps the chat's invite affordances
        // (QR / "Invite members") visible while the card shows. There's no
        // time-based message filtering anymore (the bundle is hidden by id via
        // the manifest + local hidden rows), so the default `now` cutoffDate is
        // fine -- it just anchors the placeholder display window.
        let plan: AgentBuilderCommitPlan = AgentBuilderCommitPlanner.makePlan(
            prompt: text,
            attachments: attachments,
            cloudConnectionIds: cloudConnectionIdsByRawValue,
            existingConversation: true
        )
        let textMessageId: String? = plan.textMessageId
        let bundleMessageId: String? = plan.bundleMessageId
        let summaryToPersist: AgentBuilderSummary = plan.summary
        let conversationIdForPersist: String = innerVM.conversation.id

        innerVM.isAwaitingBuilderBundleSend = true

        // Capture `innerVM` and `session` strongly (not `self`/weak): the
        // builder sheet dismisses on Make, tearing down this view-model tree,
        // but the persist + send + join must still complete. The strong hold
        // keeps the inner conversation VM alive until the bundle is sent; it
        // owns its own message writer, so it sends independently of the
        // dismissed builder.
        Task { @MainActor [innerVM, voiceMemoSnapshot, summaryToPersist, conversationIdForPersist, textMessageId, bundleMessageId, session] in
            // Persist the summary first so the chat the user returns to renders
            // the card immediately (its `summaryPublisher` picks this up) and
            // the filter set is on disk before the bundle lands.
            do {
                try await session.agentBuilderSummaryWriter().save(summaryToPersist, for: conversationIdForPersist)
            } catch {
                Log.error("AgentBuilder(existing): failed to persist summary for \(conversationIdForPersist): \(error.localizedDescription)")
            }
            do {
                try await innerVM.awaitPendingMediaUploads()
            } catch {
                Log.error("AgentBuilder(existing): pending media upload await failed: \(error.localizedDescription)")
            }
            await innerVM.sendBuilderBundle(
                text: summaryToPersist.prompt,
                voiceMemo: voiceMemoSnapshot,
                textMessageId: textMessageId,
                bundleMessageId: bundleMessageId
            )
            let slug = innerVM.conversation.invite?.urlSlug ?? ""
            guard !slug.isEmpty else {
                Log.warning("AgentBuilder(existing): no invite slug; skipping agent join")
                return
            }
            // The join must finish even after the builder sheet dismisses.
            // Unlike the draft flow, there is no draft to discard -- the user's
            // group stays -- so the join survives the view closing (like
            // `ConversationViewModel`'s committed-conversation join, the
            // opposite of the draft path).
            do {
                _ = try await session.requestAgentJoin(slug: slug, options: .agentBuilder)
            } catch {
                Log.error("AgentBuilder(existing): requestAgentJoin failed: \(error.localizedDescription)")
            }
        }
        // No in-sheet morph: the builder targets a conversation the user is
        // already in, so `AgentBuilderView` dismisses the sheet on Make and the
        // user lands back on the original chat (where the card, the agent's
        // join, and the hidden brief surface via that view's own observation).
        // `isCommitting` stays true so the dismiss doesn't trip `discard()`;
        // the Tasks above hold their own references and finish independently.
    }

    /// Map the composer's staged inputs into the `AgentBuilderSummaryAttachment`
    /// list the summary card renders — thumbnails encoded as JPEG `Data`, file
    /// metadata, voice memo levels, connection identifiers — so the summary view
    /// can show the same chips the composer just had, minus the X buttons. The
    /// id allocation, bundle detection, and summary assembly happen in
    /// `AgentBuilderCommitPlanner`; this method owns only the iOS-side
    /// (`UIImage`) encoding that can't live in ConvosCore.
    private func buildSummaryAttachments(
        voiceMemo: BuilderVoiceMemoSnapshot?,
        mediaAttachments: [PendingMediaAttachment],
        connections: Set<AgentBuilderConnection>
    ) -> [AgentBuilderSummaryAttachment] {
        var attachments: [AgentBuilderSummaryAttachment] = []
        if let voiceMemo {
            attachments.append(.voiceMemo(id: UUID(), duration: voiceMemo.duration, levels: voiceMemo.levels))
        }
        for attachment in mediaAttachments {
            switch attachment {
            case .photo(let photo):
                attachments.append(.photo(id: photo.id, thumbnailData: Self.encodedChipThumbnail(photo.image)))
            case .video(let video):
                attachments.append(.video(id: video.id, thumbnailData: video.thumbnail.flatMap(Self.encodedChipThumbnail)))
            case .file(let file):
                attachments.append(.file(
                    id: file.id,
                    filename: file.filename,
                    mimeType: file.mimeType,
                    fileSize: file.fileSize
                ))
            }
        }
        for connection in connections.sorted(by: { $0.id < $1.id }) {
            attachments.append(.connection(id: UUID(), identifier: connection.rawValue))
        }
        return attachments
    }

    private enum Constant {
        static let contentFadeMs: Int = 180
        /// Wall-clock delay from Make tap until the contact card is allowed
        /// to render. ~180ms covers the content fade, ~350ms the overlay
        /// spring; the rest (~970ms) is dwell time so the chat reveals
        /// cleanly before the card slides in. Existing conversations opened
        /// from the list bypass this entirely.
        static let contactCardRevealDelayMs: Int = 1500
        /// Pixel size used to bake summary chip thumbnails into the persisted
        /// `DBAgentBuilderSummary` row. The summary card renders chips at
        /// 80pt; 240px (3x Retina) keeps them crisp without persisting a
        /// multi-megabyte full-resolution PNG inside the JSON column — that
        /// was the main-thread bottleneck on later `summarySync` reads.
        static let chipThumbnailPixelSize: CGFloat = 240
        /// Slight quality drop traded for a much smaller payload — chips render
        /// inside an 80pt square so artifacts are imperceptible at that size.
        static let chipThumbnailJpegQuality: CGFloat = 0.7
    }

    /// Downscale a captured photo / extracted video frame to the chip size
    /// the summary card actually displays and re-encode as JPEG before
    /// storage. `UIImage.preparingThumbnail(of:)` is the system fast path —
    /// it asks ImageIO to decode straight at the target size instead of
    /// inflating the full image first. Combined with JPEG (vs the previous
    /// PNG round-trip), this drops a ~1MB-per-photo summary row down to
    /// a few KB so the `summarySync` `JSONDecoder` pass on later opens stays
    /// sub-millisecond regardless of how many photos the user attached.
    private static func encodedChipThumbnail(_ image: UIImage) -> Data? {
        let target: CGSize = CGSize(
            width: Constant.chipThumbnailPixelSize,
            height: Constant.chipThumbnailPixelSize
        )
        let resized: UIImage = image.preparingThumbnail(of: target) ?? image
        return resized.jpegData(compressionQuality: Constant.chipThumbnailJpegQuality)
    }

    // MARK: - Dismiss cleanup

    /// Tear down the in-flight draft. Cancels conversation-creation tasks
    /// and the agent-join request, and — if the conversation became real
    /// and the agent has already joined — sets consent to denied so
    /// the agent sees us depart. Local conversation row cleanup is
    /// handled by the draft repository when this VM deallocates.
    func discard() {
        guard !didDiscard else { return }
        didDiscard = true
        if targetsExistingConversation {
            // The builder targeted an existing conversation: there is no draft
            // to tear down, and we must never leave / delete the user's group.
            // A pre-Make cancel just releases the staged-but-unsent inputs.
            // (Post-Make, `isCommitting`/`hasCommitted` are set, so the inner
            // bundle send + agent join — fired in `commitToExistingConversation`
            // capturing only `session` — keep running independently.)
            if !isCommitting {
                voiceMemoRecorder.cancelRecording()
                newConversationViewModel.conversationViewModel?.cleanupPendingMediaAttachments()
                cleanupQueuedInitialAttachments()
            }
            return
        }
        agentJoinTask?.cancel()
        didRequestAgentJoin = true // suppress any late retries
        // Skip recording/attachment cleanup while a commit is mid-flight —
        // `sendBuilderBundle` still holds references to those temp files
        // until `hasCommitted` flips. Cleaning them here would race the
        // in-flight upload and leave the bundle pointing at deleted paths.
        if !isCommitting {
            voiceMemoRecorder.cancelRecording()
            // File picker stages copies into `FileManager.default.temporaryDirectory`;
            // those temp copies are otherwise orphaned because `dismissWithDeletion`
            // doesn't iterate `pendingMediaAttachments`. Clean them up explicitly.
            newConversationViewModel.conversationViewModel?.cleanupPendingMediaAttachments()
            // Attachments staged before the inner VM resolved haven't been
            // forwarded yet -- `cleanupPendingMediaAttachments()` only walks
            // what's already inside that VM. Walk the local queue too so the
            // file-picker / camera / photo-picker temp files don't leak when
            // the user discards before the placeholder window closes.
            cleanupQueuedInitialAttachments()
        }

        let conversation = newConversationViewModel.conversationViewModel?.conversation

        newConversationViewModel.dismissWithDeletion()

        // Once the draft has been committed (real XMTP group id, not a
        // `draft-...` placeholder) we always run the consent-delete path
        // so the user leaves the XMTP group. Without this, dropping out
        // before the agent joined would delete the local row but leave
        // the XMTP group on the server — the next sync would re-add a
        // row to the conversations list and the user would see the
        // discarded convo come back.
        guard let conversation, !conversation.isDraft else { return }

        Task { [session] in
            do {
                let writer = session.messagingService().conversationConsentWriter()
                try await writer.delete(conversation: conversation)
            } catch {
                Log.error("AgentBuilder discard: failed to leave conversation \(conversation.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Agent join

    private func requestAgentJoinIfNeeded() {
        guard !didRequestAgentJoin else { return }
        guard let conversation = newConversationViewModel.conversationViewModel?.conversation else {
            Log.warning("AgentBuilderViewModel: reached .ready but no conversation available")
            return
        }
        let slug = conversation.invite?.urlSlug ?? ""
        guard !slug.isEmpty else {
            Log.warning("AgentBuilderViewModel: reached .ready but invite slug is empty")
            return
        }
        didRequestAgentJoin = true

        agentJoinTask?.cancel()
        // Capture `session` only, not `self`: the join needs nothing back from
        // the VM, and not capturing `self` avoids a cycle through the stored
        // `agentJoinTask`. `deinit` and `discard()` cancel the task on teardown,
        // which is intentional here (and the opposite of the committed-
        // conversation join in `ConversationViewModel`, which must survive the
        // view closing): closing the builder discards the draft conversation --
        // leaving / deleting the group -- so there's nothing left to join.
        agentJoinTask = Task { [session] in
            do {
                _ = try await session.requestAgentJoin(slug: slug, options: .agentBuilder)
            } catch is CancellationError {
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                return
            } catch {
                Log.error("AgentBuilderViewModel: requestAgentJoin failed: \(error.localizedDescription)")
            }
        }
    }

    private func emitBuiltAgentMetric(text: String, isSuccess: Bool) {
        let durationSecs: Float = Float(CFAbsoluteTimeGetCurrent() - buildStartedAt)
        let charCount: Int = text.count
        let wordCount: Int = text.split(whereSeparator: { $0.isWhitespace }).count
        let attachments: [PendingMediaAttachment] = newConversationViewModel.conversationViewModel?.pendingMediaAttachments ?? []
        let attachmentMimeTypes: [String] = attachments.map { attachment -> String in
            switch attachment {
            case .photo: return "image/jpeg"
            case .video: return "video/mp4"
            case .file(let payload): return payload.mimeType
            }
        }
        let hasVoiceMemo: Bool = (recordedVoiceMemo != nil)
        let voiceMemoDuration: Float = recordedVoiceMemo.map { Float($0.duration) } ?? 0
        let connectionTypes: [String] = enabledConnections.map { $0.rawValue }
        let metricsEntryMode: ConvosMetrics.AgentBuilderEntryMode = (entryMode == .voiceMemo) ? .voiceMemo : .composer
        let actions: any CoreActions = coreActions
        Task {
            await actions.builtAgent(
                buildDuration: durationSecs,
                instructionCharCount: charCount,
                instructionWordCount: wordCount,
                attachmentTypes: attachmentMimeTypes,
                hasVoiceMemo: hasVoiceMemo,
                voiceMemoDuration: voiceMemoDuration,
                connectionTypes: connectionTypes,
                entryMode: metricsEntryMode,
                isSuccess: isSuccess
            )
        }
    }
}
