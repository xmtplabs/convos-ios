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

/// Whether the composer's current text was dropped by the dice (`.dice`) or
/// typed / edited by the user (`.manual`). Drives dice *visibility* only: the
/// dice stays visible while re-rolling (text stays `.dice`) and hides as soon
/// as the user edits (flips to `.manual`). Deliberately separate from the
/// metrics-facing `fromPromptHint` flag, which survives edits.
enum ComposerTextSource {
    case manual
    case dice
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

    /// Source of the current `composerText`, used purely to decide whether the
    /// dice control stays visible (see `allowsDiceRoll`). Flips to `.manual` on
    /// any user keystroke via `composerTextBinding`'s setter; a programmatic
    /// dice roll keeps it `.dice`.
    private(set) var composerTextSource: ComposerTextSource = .manual

    /// Metrics-only: `true` once a dice hint seeded the prompt, and stays true
    /// through subsequent edits. Reset to `false` only when the composer is
    /// emptied. Reported on the `built_agent` event as `from_prompt_hint`.
    private(set) var fromPromptHint: Bool = false

    /// Metrics-only: running count of dice taps in this builder session.
    /// Reported on every `prompt_hint_tapped` event and on `built_agent`.
    private(set) var promptHintTapCount: Int = 0

    /// Last hint dropped by the dice, so a re-roll can avoid an immediate
    /// repeat. Not observed -- it only influences the next roll.
    @ObservationIgnored
    private var lastRolledHint: String?

    /// Binding the composer's text field uses instead of `$viewModel.composerText`.
    /// A genuine keystroke changes the text and flips the source to `.manual`
    /// (hiding the dice once non-empty), while a dice roll assigns `composerText`
    /// directly and keeps the source `.dice` (dice stays visible for re-rolls).
    /// A re-presented sheet reconstructs the field, which can echo the current
    /// value back through this setter with no real edit, so writes that don't
    /// change the text are ignored -- otherwise the first dice tap after a reopen
    /// would register a phantom edit, flip the source to `.manual`, and hide the
    /// dice. Clearing the box resets the metrics `fromPromptHint` flag.
    var composerTextBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.composerText ?? "" },
            set: { [weak self] newValue in
                guard let self else { return }
                guard newValue != self.composerText else { return }
                self.composerText = newValue
                self.composerTextSource = .manual
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.fromPromptHint = false
                }
            }
        )
    }

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

    /// Direct-builder only: prompt captured at Make, held until the inner
    /// conversation is ready enough to expose an invite slug, then handed to
    /// the repository. Cleared once the generation has been kicked off.
    @ObservationIgnored
    private var pendingDirectPrompt: String?
    /// Direct-builder only: the dev variant slug captured at Make (`nil` when no
    /// variant is selected), held alongside the prompt and handed to the
    /// repository with it. Capturing once at Make -- not re-reading the device
    /// selection when the deferred generation finally starts -- is what keeps a
    /// mid-build variant switch from splitting generation and routing.
    @ObservationIgnored
    private var pendingDirectVariantId: String?
    @ObservationIgnored
    private var didStartDirectGeneration: Bool = false
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
        // Suppress the contact card for the entire builder lifetime. The agent
        // joins once the generation finishes, which can happen while the user
        // is still drafting, in which case the inner conversation view already
        // has the card prepared -- hidden under the composer overlay. If we
        // waited until `commit()` to flip the gate, that prepared card would
        // flash visible during the morph reveal. The `suppressesContactCard`
        // flag on `NewConversationViewModel` propagates the gate across the
        // inbox-acquisition VM swap (`configureWithMessagingService`), so both
        // the placeholder VM and its real replacement stay suppressed.
        self.newConversationViewModel.suppressesContactCard = true
        self.newConversationViewModel.onReachedReady = { [weak self] in
            guard let self else { return }
            self.drainInitialAttachmentsIfNeeded()
            // The existing-conversation flow defers the generation to `commit()`
            // so we only build once the user confirms by tapping Make.
            guard self.targetsExistingConversation == false else { return }
            // No agent is eagerly provisioned: the repository invites the
            // resulting template once the generation finishes. We only need to
            // start the generation once the conversation has an invite slug, in
            // case Make was tapped before the conversation was ready.
            self.startDirectGenerationIfReady()
        }
        cloudConnectionsCancellable = session.cloudConnectionRepository().connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.cloudConnections = connections.filter { $0.provider == .composio }
            }
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

    // MARK: - Dice / prompt hints

    /// Whether the dice control's draft preconditions hold: no staged
    /// attachments (media, voice memo, recording, or connections) and the
    /// composer is either empty or still showing an unedited dice result. The
    /// hints-non-empty check is layered on by the view (`isDiceVisible`).
    var allowsDiceRoll: Bool {
        guard pendingMediaAttachments.isEmpty else { return false }
        guard recordedVoiceMemo == nil, !isRecordingVoiceMemo else { return false }
        guard enabledConnections.isEmpty else { return false }
        let trimmed: String = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || composerTextSource == .dice
    }

    /// Drops a random hint into the composer, avoiding an immediate repeat of
    /// the current one. Marks the source `.dice` so the dice stays visible for
    /// repeated re-rolls, sets the metrics `fromPromptHint` flag (which survives
    /// later edits), and fires a `prompt_hint_tapped` metric carrying the
    /// running tap count.
    func rollDice(hints: [String]) {
        let available: [String] = hints.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !available.isEmpty else { return }
        let chosen: String = Self.randomHint(from: available, avoiding: lastRolledHint)
        lastRolledHint = chosen
        composerText = chosen
        composerTextSource = .dice
        fromPromptHint = true
        promptHintTapCount += 1
        emitPromptHintTappedMetric()
    }

    /// Picks a random hint, excluding `current` when there is more than one
    /// option so a tap never lands on the same hint twice in a row.
    private static func randomHint(from hints: [String], avoiding current: String?) -> String {
        let pool: [String]
        if let current, hints.count > 1 {
            pool = hints.filter { $0 != current }
        } else {
            pool = hints
        }
        return pool.randomElement() ?? hints.first ?? ""
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

        // The in-chat builder needs the inner conversation VM resolved (the
        // generation reads its id + invite slug). Bail before clearing the
        // composer or emitting a metric so a too-early Make can be retried.
        if targetsExistingConversation, newConversationViewModel.conversationViewModel == nil {
            Log.warning("AgentBuilder(existing): commit attempted before inner conversation ready; leaving composer intact")
            return
        }

        isCommitting = true

        let textToSend = composerText
        composerText = ""
        // Reset the dice visibility state now that the draft text is cleared.
        // The metrics flags (`fromPromptHint`, `promptHintTapCount`) are read by
        // `emitBuiltAgentMetric` just below, so they are left intact here.
        composerTextSource = .manual
        lastRolledHint = nil
        emitBuiltAgentMetric(text: textToSend, isSuccess: true)

        // Hand the prompt to the session-scoped repository, which submits the
        // generation, polls it, and invites the resulting template into the
        // conversation. No XMTP bundle send and no eager agent. The in-chat
        // variant's conversation is already visible, so it dismisses back to the
        // chat without the reveal tail; the home flow runs the reveal/visibility
        // tail below so the chat animates in and the agent's contact card
        // appears once it joins.
        // Capture the active variant once, here at Make. Reading the device
        // selection now (rather than when the deferred generation starts) is the
        // split-brain guard: a mid-build switch can't generate under one variant
        // and route/stamp under another.
        let variantId = FeatureFlags.shared.selectedAgentVariant?.slug
        startDirectGeneration(prompt: textToSend, variantId: variantId)
        if targetsExistingConversation { return }

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

    private enum Constant {
        static let contentFadeMs: Int = 180
        /// Wall-clock delay from Make tap until the contact card is allowed
        /// to render. ~180ms covers the content fade, ~350ms the overlay
        /// spring; the rest (~970ms) is dwell time so the chat reveals
        /// cleanly before the card slides in. Existing conversations opened
        /// from the list bypass this entirely.
        static let contactCardRevealDelayMs: Int = 1500
    }

    // MARK: - Dismiss cleanup

    /// Tear down the in-flight draft. Cancels conversation-creation work and —
    /// if the conversation became real — sets consent to denied so the agent
    /// sees us depart. Local conversation row cleanup is handled by the draft
    /// repository when this VM deallocates.
    func discard() {
        guard !didDiscard else { return }
        didDiscard = true
        if targetsExistingConversation {
            // The builder targeted an existing conversation: there is no draft
            // to tear down, and we must never leave / delete the user's group.
            // A pre-Make cancel just releases the staged-but-unsent inputs.
            // (Post-Make, `isCommitting`/`hasCommitted` are set, so the
            // generation submitted from `startDirectGeneration` keeps running
            // independently of this view-model teardown.)
            if !isCommitting {
                voiceMemoRecorder.cancelRecording()
                newConversationViewModel.conversationViewModel?.cleanupPendingMediaAttachments()
                cleanupQueuedInitialAttachments()
            }
            return
        }
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
}

// MARK: - Direct builder

extension AgentBuilderViewModel {
    /// Capture the prompt and start the generation as soon as the conversation
    /// has an invite slug. If Make was tapped before the conversation was
    /// ready, `onReachedReady` re-invokes `startDirectGenerationIfReady()`.
    private func startDirectGeneration(prompt: String, variantId: String?) {
        pendingDirectPrompt = prompt
        pendingDirectVariantId = variantId
        startDirectGenerationIfReady()
    }

    /// Hand the captured prompt to the session-scoped repository once a slug is
    /// available. Idempotent via `didStartDirectGeneration` so the
    /// `onReachedReady` re-entry can't double-submit.
    private func startDirectGenerationIfReady() {
        guard !didStartDirectGeneration else { return }
        guard let prompt = pendingDirectPrompt else { return }
        guard let conversation = newConversationViewModel.conversationViewModel?.conversation else {
            Log.warning("AgentBuilder(direct): no conversation available yet; deferring generation start")
            return
        }
        let slug = conversation.invite?.urlSlug ?? ""
        guard !slug.isEmpty else {
            Log.warning("AgentBuilder(direct): invite slug empty; deferring generation start")
            return
        }
        didStartDirectGeneration = true
        pendingDirectPrompt = nil
        let variantId = pendingDirectVariantId
        pendingDirectVariantId = nil
        let conversationId = conversation.id
        let photos: [PendingPhotoAttachment] = directBuildPhotos()
        var attachmentInputs: [AgentBuildAttachmentInput] = []
        var summaryAttachments: [AgentBuilderSummaryAttachment] = []
        // Build the upload inputs and the summary chips together so a photo that
        // fails compression is dropped from both -- otherwise its thumbnail would
        // render on the card for an attachment that was never sent to the backend.
        for photo in photos {
            guard let data = ImageCompression.compressForPhotoAttachment(photo.image) else {
                Log.error("AgentBuilder(direct): failed to compress photo \(photo.id); excluding from upload and summary")
                continue
            }
            attachmentInputs.append(AgentBuildAttachmentInput(data: data, mimeType: "image/jpeg", filename: nil))
            summaryAttachments.append(.photo(id: photo.id, thumbnailData: Self.thumbnailData(for: photo.image)))
        }
        if let memo = recordedVoiceMemo, let voiceInput = Self.voiceAttachmentInput(url: memo.url) {
            attachmentInputs.append(voiceInput)
            summaryAttachments.append(.voiceMemo(id: UUID(), duration: memo.duration, levels: voiceMemoAudioLevels))
        }
        // Generation awareness gets only the cloud service ids (device kinds
        // like Apple Health aren't catalog services and would 400). The summary
        // carries every enabled connection + captured cloud-connection ids so
        // `AgentBuilderConnectionGrantReplayer` fires the real grants post-join.
        let connectionServiceIds: [String] = enabledConnections.compactMap { $0.cloudServiceId }
        for connection in enabledConnections {
            summaryAttachments.append(.connection(id: UUID(), identifier: connection.rawValue))
        }
        var cloudConnectionIds: [String: String] = [:]
        for (connection, cloudConnectionId) in capturedCloudConnectionIds {
            cloudConnectionIds[connection.rawValue] = cloudConnectionId
        }
        // Pre-allocate the prompt's client message id so the creation-prompt
        // card represents it (bundled by id) instead of a bare bubble, matching
        // the legacy flow. nil for an attachment-only build (empty prompt).
        let promptMessageId: String? = prompt.isEmpty ? nil : UUID().uuidString
        // Only an existing group has an audience for the attachments: a new
        // conversation has no other members during the build (and the joining
        // agent is excluded by publishing pre-join), and later-invited members
        // can't decrypt pre-join messages. So we network the attachments as the
        // legacy encrypted bundle only for the in-chat variant -- elsewhere they
        // ride the generation API only. (The agent always built from the API
        // copy, so it never needs them as messages.)
        let hasComposerAttachments: Bool = !photos.isEmpty || recordedVoiceMemo != nil
        let networksAttachmentBundle: Bool = targetsExistingConversation && hasComposerAttachments
        let bundleMessageId: String? = networksAttachmentBundle ? UUID().uuidString : nil
        let voiceMemoSnapshot: BuilderVoiceMemoSnapshot? = recordedVoiceMemo.map {
            BuilderVoiceMemoSnapshot(url: $0.url, duration: $0.duration, levels: voiceMemoAudioLevels)
        }
        session.agentTemplateRepository().startGeneration(
            prompt: prompt,
            conversationId: conversationId,
            slug: slug,
            attachments: attachmentInputs,
            connections: connectionServiceIds,
            variantId: variantId
        )
        var bundledIds: Set<String> = []
        if let promptMessageId { bundledIds.insert(promptMessageId) }
        if let bundleMessageId { bundledIds.insert(bundleMessageId) }
        persistCreationPromptCard(
            prompt: prompt,
            conversationId: conversationId,
            attachments: summaryAttachments,
            cloudConnectionIds: cloudConnectionIds,
            bundledMessageIds: bundledIds
        )
        // We always publish pre-join (`awaitsAgentJoin: false`): the agent built
        // from the prompt + attachments via the generation API, so it must not
        // also receive them as chat messages (that lands them in an epoch the
        // joining agent can't read, so the user/other members see them but the
        // agent doesn't double-reply). The prompt is sent so it shows in chat and
        // persists (the card anchors to it).
        if networksAttachmentBundle, let innerVM = newConversationViewModel.conversationViewModel {
            // Existing group: send the prompt + the encrypted attachment bundle
            // so other members see the photos/voice. `sendBuilderBundle` reads
            // and clears the composer's pending attachments and resets the voice
            // recorder itself (and hides the staging chips via the flag below
            // during the upload window), so don't clear them separately here.
            innerVM.isAwaitingBuilderBundleSend = true
            Task {
                try? await innerVM.awaitPendingMediaUploads()
                await innerVM.sendBuilderBundle(
                    text: prompt,
                    voiceMemo: voiceMemoSnapshot,
                    textMessageId: promptMessageId,
                    bundleMessageId: bundleMessageId,
                    awaitsAgentJoin: false
                )
            }
        } else {
            // Home flow (or no attachments): the attachment bytes already went to
            // the generation API, so clear the composer's staged attachments
            // (otherwise they linger in the input bar after Make) and send the
            // prompt text-only.
            newConversationViewModel.conversationViewModel?.cleanupPendingMediaAttachments()
            if recordedVoiceMemo != nil {
                cancelRecordedVoiceMemo()
            }
            if let promptMessageId, let innerVM = newConversationViewModel.conversationViewModel {
                Task {
                    await innerVM.sendBuilderBundle(
                        text: prompt,
                        voiceMemo: nil,
                        textMessageId: promptMessageId,
                        bundleMessageId: nil,
                        awaitsAgentJoin: false
                    )
                }
            }
        }
    }

    /// Photos currently staged in the composer (camera + library), the only
    /// attachment kind wired into the direct build for now. Video is excluded
    /// (the generation API has no video MIME); files/voice come later.
    private func directBuildPhotos() -> [PendingPhotoAttachment] {
        let pending: [PendingMediaAttachment] = newConversationViewModel.conversationViewModel?.pendingMediaAttachments ?? []
        return pending.compactMap { (attachment: PendingMediaAttachment) -> PendingPhotoAttachment? in
            guard case .photo(let photo) = attachment else { return nil }
            return photo
        }
    }

    /// Reads the recorded voice memo's m4a bytes for upload. The backend
    /// transcribes audio to text before generation; `audio/m4a` is in the
    /// allowlist.
    private static func voiceAttachmentInput(url: URL) -> AgentBuildAttachmentInput? {
        guard let data = try? Data(contentsOf: url) else {
            Log.error("AgentBuilder(direct): failed to read voice memo at \(url.lastPathComponent)")
            return nil
        }
        return AgentBuildAttachmentInput(data: data, mimeType: "audio/m4a", filename: "voice.m4a")
    }

    /// Small JPEG thumbnail for the creation-prompt card chip, kept well under
    /// the full upload size so the persisted summary row stays light.
    private static func thumbnailData(for image: UIImage) -> Data? {
        let maxDimension: CGFloat = 240
        let longestSide: CGFloat = max(image.size.width, image.size.height)
        let scale: CGFloat = longestSide > maxDimension ? maxDimension / longestSide : 1
        let target: CGSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(size: target)
        let scaled: UIImage = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    /// Persist an `AgentBuilderSummary` so the existing summary-card rendering
    /// shows the creator's prompt at the top of the chat while the agent
    /// builds (reuses `MessagesListProcessor`'s pending-card path), and so the
    /// `AgentBuilderConnectionGrantReplayer` can fire post-join grants from its
    /// `.connection` attachments + `cloudConnectionIds`. `bundledMessageIds`
    /// carries the prompt's client message id (when the prompt is non-empty) so
    /// the card represents that sent message instead of a bare bubble, matching
    /// the legacy flow; the attachments still ride the generation API, not XMTP.
    /// Once the prompt message lands, `reconstructBuilderCards` anchors the card
    /// to it, so it persists past the 180s pending window and across relaunch.
    /// Set on the inner VM synchronously for the home-flow morph / no first-frame
    /// flash, and persisted so it survives relaunch and reaches the
    /// existing-conversation on-screen VM via its summary publisher.
    private func persistCreationPromptCard(
        prompt: String,
        conversationId: String,
        attachments: [AgentBuilderSummaryAttachment],
        cloudConnectionIds: [String: String],
        bundledMessageIds: Set<String>
    ) {
        let summary = AgentBuilderSummary(
            prompt: prompt,
            attachments: attachments,
            cutoffDate: Date(),
            bundledMessageIds: bundledMessageIds,
            cloudConnectionIds: cloudConnectionIds,
            existingConversation: targetsExistingConversation
        )
        newConversationViewModel.conversationViewModel?.agentBuilderSummary = summary
        Task { [session] in
            do {
                try await session.agentBuilderSummaryWriter().save(summary, for: conversationId)
            } catch {
                Log.error("AgentBuilder(direct): failed to persist creation prompt summary: \(error.localizedDescription)")
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
        let fromHint: Bool = fromPromptHint
        let tapCount: Int = promptHintTapCount
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
                isSuccess: isSuccess,
                fromPromptHint: fromHint,
                tapCount: tapCount
            )
        }
    }

    /// Fires the `prompt_hint_tapped` event on each dice tap, carrying the
    /// running per-session tap count, through the shared metrics `CoreActions`.
    private func emitPromptHintTappedMetric() {
        let tapCount: Int = promptHintTapCount
        let actions: any CoreActions = coreActions
        Task {
            await actions.promptHintTapped(tapCount: tapCount)
        }
    }
}
