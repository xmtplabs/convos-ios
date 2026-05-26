import Combine
import ConvosConnections
import ConvosCore
import ConvosCoreiOS
import Foundation
import Observation
import Sentry
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

    static let googleCalendarServiceId: String = "googlecalendar"
}

@MainActor
@Observable
final class AgentBuilderViewModel: Identifiable {
    let id: UUID = UUID()
    let session: any SessionManagerProtocol

    let newConversationViewModel: NewConversationViewModel

    var composerText: String = ""

    /// Routes attachment state through the underlying conversation view
    /// model so eager upload + thumbnail generation are reused. The view
    /// reads these via SwiftUI's Observation tracking through the chain.
    var pendingMediaAttachments: [PendingMediaAttachment] {
        newConversationViewModel.conversationViewModel?.pendingMediaAttachments ?? []
    }

    /// Shares the inner conversation VM's voice-memo recorder so the same
    /// audio file flows through to `sendVoiceMemo()` on commit. The
    /// builder's UI reacts to recorder state changes via Observation.
    var voiceMemoRecorder: VoiceMemoRecorder? {
        newConversationViewModel.conversationViewModel?.voiceMemoRecorder
    }

    var isRecordingVoiceMemo: Bool {
        guard let recorder = voiceMemoRecorder else { return false }
        if case .recording = recorder.state { return true }
        return false
    }

    var recordedVoiceMemo: (url: URL, duration: TimeInterval)? {
        guard let recorder = voiceMemoRecorder else { return nil }
        if case let .recorded(url, duration) = recorder.state { return (url, duration) }
        return nil
    }

    var voiceMemoAudioLevels: [Float] {
        voiceMemoRecorder?.audioLevels ?? []
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
    @ObservationIgnored
    private var pendingConnectionGrantTask: Task<Void, Never>?
    /// Whether the composer text field was focused at the moment the user
    /// kicked off a voice memo. Read by the stop-recording action so we can
    /// return the keyboard to the composer where the user left off.
    @ObservationIgnored
    private var restoreComposerFocusAfterRecording: Bool = false

    init(session: any SessionManagerProtocol) {
        self.session = session
        self.newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .newAgent
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
        pendingConnectionGrantTask?.cancel()
    }

    // MARK: - Composer mutations

    func addPhotoAttachment(_ image: UIImage) {
        newConversationViewModel.conversationViewModel?.addPhotoAttachment(image)
    }

    func addVideoAttachment(url: URL) {
        newConversationViewModel.conversationViewModel?.addVideoAttachment(url: url)
    }

    func addFileAttachment(url: URL, filename: String, mimeType: String, fileSize: Int) {
        newConversationViewModel.conversationViewModel?.addFileAttachment(
            url: url,
            filename: filename,
            mimeType: mimeType,
            fileSize: fileSize
        )
    }

    func removeAttachment(id: UUID) {
        newConversationViewModel.conversationViewModel?.removeMediaAttachment(id: id)
    }

    func startVoiceMemoRecording(restoreComposerFocusAfter: Bool) {
        guard let recorder = voiceMemoRecorder else { return }
        do {
            try recorder.startRecording()
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
        voiceMemoRecorder?.stopRecording()
        let shouldRestore = restoreComposerFocusAfterRecording
        restoreComposerFocusAfterRecording = false
        return shouldRestore
    }

    func cancelRecordedVoiceMemo() {
        voiceMemoRecorder?.cancelRecording()
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
        guard !isConnectingCloud else { return }
        switch connection {
        case .appleHealth:
            enabledConnections.insert(connection)
        case .googleCalendar:
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

    /// Make button is enabled as soon as the composer has any content.
    /// Tapping Make before the state machine reaches `.ready` is fine —
    /// the morph animates the user into `ConversationView`, which surfaces
    /// its own "Agent is joining…" state, and the message is queued
    /// via `ConversationStateMachine.sendMessage` (which already
    /// serializes against `.ready`).
    var isMakeEnabled: Bool {
        !composerText.isEmpty
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
        isCommitting = true

        let textToSend = composerText
        composerText = ""

        if let innerVM = newConversationViewModel.conversationViewModel {
            // Allocate the bundle's `clientMessageId`s synchronously so they
            // can land in `AgentBuilderSummary.bundledMessageIds` BEFORE
            // the writer ever touches the DB. `MessagesListProcessor` then
            // filters by id, not by timestamp — a slow multi-remote upload
            // can no longer leak a bare bundle bubble past the summary card.
            let textMessageId: String? = textToSend.isEmpty ? nil : UUID().uuidString
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
            let willSendBundle: Bool = voiceMemoSnapshot != nil || !innerVM.pendingMediaAttachments.isEmpty
            let bundleMessageId: String? = willSendBundle ? UUID().uuidString : nil
            var bundledMessageIds: Set<String> = []
            if let textMessageId { bundledMessageIds.insert(textMessageId) }
            if let bundleMessageId { bundledMessageIds.insert(bundleMessageId) }

            let summary: AgentBuilderSummary = buildSummary(
                prompt: textToSend,
                voiceMemo: recordedVoiceMemo,
                voiceMemoLevels: voiceMemoAudioLevels,
                mediaAttachments: innerVM.pendingMediaAttachments,
                connections: enabledConnections,
                bundledMessageIds: bundledMessageIds
            )
            innerVM.agentBuilderSummary = summary
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
            let summaryToPersist: AgentBuilderSummary = summary
            let conversationIdForPersist: String = innerVM.conversation.id
            let sessionForPersist = session
            Task { @MainActor [weak innerVM, textToSend, voiceMemoSnapshot, textMessageId, bundleMessageId, summaryToPersist, conversationIdForPersist, sessionForPersist] in
                guard let innerVM else { return }
                // Persist the summary (with its `bundledMessageIds`) BEFORE
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
                    text: textToSend,
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
            // Promote the claimed cache row into a visible conversation
            // AFTER `hasCommitted` flips. The `.onChange(of: hasCommitted)`
            // inside `AgentBuilderView` fires the `onCommitted` callback,
            // which the inline-builder host (`ConversationsView`) uses to
            // present the committed conversation as a sheet. If we flip
            // `isUnused = false` first, the chats list becomes non-empty,
            // `isEmptyCTAActive` flips, the inline builder unmounts, and
            // the onChange handler never fires — leaving no sheet.
            // Sequencing the commit AFTER the state change keeps the
            // host's callback intact, then the cache flip arrives once
            // the sheet is already on its way up.
            if let claimedId = self.newConversationViewModel.claimedConversationId {
                await self.session.commitClaimedConversation(id: claimedId)
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Constant.contactCardRevealDelayMs))
            guard let self else { return }
            // Clear both gates: the wrapper so any future VM swap also lands
            // unsuppressed, and the current VM so the card actually reveals.
            self.newConversationViewModel.suppressesContactCard = false
            self.newConversationViewModel.conversationViewModel?.allowsContactCard = true
        }

        scheduleConnectionGrants()
    }

    /// Build the AgentBuilderSummary that renders as the first cell of the
    /// post-Make conversation. Captures chip-ready data (thumbnails encoded as
    /// PNG, file metadata, voice memo levels, connection identifiers) so the
    /// summary view can render the same chips the composer just had — minus
    /// the X buttons.
    private func buildSummary(
        prompt: String,
        voiceMemo: (url: URL, duration: TimeInterval)?,
        voiceMemoLevels: [Float],
        mediaAttachments: [PendingMediaAttachment],
        connections: Set<AgentBuilderConnection>,
        bundledMessageIds: Set<String>
    ) -> AgentBuilderSummary {
        var attachments: [AgentBuilderSummaryAttachment] = []
        if let voiceMemo {
            attachments.append(.voiceMemo(id: UUID(), duration: voiceMemo.duration, levels: voiceMemoLevels))
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
        // `cutoffDate` still gates agent-side groups (pre-Make hello
        // messages from the agent) — we don't control the agent's send
        // timing so timestamps are the only signal there. User-side filtering
        // is by-id via `bundledMessageIds`, which doesn't suffer the
        // upload-stretch race that the old user-side cutoff pad did.
        return AgentBuilderSummary(
            prompt: prompt,
            attachments: attachments,
            cutoffDate: Date(),
            bundledMessageIds: bundledMessageIds
        )
    }

    private func scheduleConnectionGrants() {
        guard !enabledConnections.isEmpty else { return }
        let connections = enabledConnections
        let capturedIds = capturedCloudConnectionIds
        pendingConnectionGrantTask?.cancel()
        pendingConnectionGrantTask = Task { @MainActor [weak self] in
            let deadline: Date = Date().addingTimeInterval(Constant.agentJoinTimeoutS)
            while !Task.isCancelled, Date() < deadline {
                if let convoVM = self?.newConversationViewModel.conversationViewModel,
                   convoVM.conversation.hasAgent {
                    self?.fireConnectionGrants(connections, capturedIds: capturedIds, in: convoVM)
                    return
                }
                try? await Task.sleep(for: .milliseconds(Constant.agentPollIntervalMs))
            }
            guard !Task.isCancelled else { return }
            let message: String = "AgentBuilder: timed out after \(Int(Constant.agentJoinTimeoutS))s waiting for agent to join — \(connections.count) connection grant(s) skipped"
            Log.error(message)
            SentrySDK.capture(message: message) { scope in
                scope.setLevel(.warning)
                scope.setTag(value: "agent_join_timeout", key: "agent_builder")
                scope.setExtra(value: connections.count, key: "skipped_connection_count")
                scope.setExtra(value: connections.map(\.id).sorted().joined(separator: ","), key: "skipped_connections")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Fires the user-enabled connection grants against the now-real conversation.
    /// Device kinds go through `ConversationConnectionsViewModel.toggleDeviceConnection`
    /// (it owns the `EnablementStore` write + per-agent fanout + connection event).
    /// Cloud kinds bypass that VM's `cloudRows` lookup — the freshly-constructed VM's
    /// `.receive(on:.main)` subscription leaves rows empty for one runloop tick, racy
    /// when we tap Make right after OAuth completes. We use the
    /// `CloudConnection.id` we captured at toggle-on time and fan out the grant
    /// directly via the messaging service's writers, mirroring what
    /// `ConversationConnectionsViewModel.grant(connectionId:providerId:)` does.
    private func fireConnectionGrants(
        _ connections: Set<AgentBuilderConnection>,
        capturedIds: [AgentBuilderConnection: String],
        in convoVM: ConversationViewModel
    ) {
        let connectionsVM = convoVM.makeConversationConnectionsViewModel()
        for connection in connections {
            switch connection {
            case .appleHealth:
                connectionsVM.toggleDeviceConnection(.health)
            case .googleCalendar:
                guard let connectionId = capturedIds[connection] else {
                    Log.warning("AgentBuilder: no captured CloudConnection.id for \(connection.id) — grant skipped")
                    continue
                }
                fireCloudGrant(
                    connectionId: connectionId,
                    serviceId: AgentBuilderConnection.googleCalendarServiceId,
                    in: convoVM
                )
            }
        }
    }

    private func fireCloudGrant(
        connectionId: String,
        serviceId: String,
        in convoVM: ConversationViewModel
    ) {
        let agentInboxIds: [String] = convoVM.conversation.members
            .filter(\.isAgent)
            .map(\.profile.inboxId)
        guard !agentInboxIds.isEmpty else { return }
        let messagingService = session.messagingService()
        let grantWriter = messagingService.connectionGrantWriter()
        let connectionEventWriter = messagingService.connectionEventWriter()
        let conversationId: String = convoVM.conversation.id
        let providerId: String = "composio.\(serviceId)"
        Task {
            var grantedAgents: [String] = []
            for agent in agentInboxIds {
                do {
                    try await grantWriter.grantConnection(connectionId, to: conversationId, grantedToInboxId: agent)
                    grantedAgents.append(agent)
                } catch {
                    Log.error("AgentBuilder: grantConnection failed for \(serviceId) agent \(agent): \(error.localizedDescription)")
                }
            }
            if let representative = grantedAgents.first {
                try? await connectionEventWriter.sendGranted(
                    providerId: providerId,
                    capability: nil,
                    grantedToInboxId: representative,
                    in: conversationId
                )
            }
        }
    }

    private enum Constant {
        static let contentFadeMs: Int = 180
        static let agentPollIntervalMs: Int = 250
        static let agentJoinTimeoutS: TimeInterval = 30
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
        agentJoinTask?.cancel()
        pendingConnectionGrantTask?.cancel()
        didRequestAgentJoin = true // suppress any late retries
        voiceMemoRecorder?.cancelRecording()
        // File picker stages copies into `FileManager.default.temporaryDirectory`;
        // those temp copies are otherwise orphaned because `dismissWithDeletion`
        // doesn't iterate `pendingMediaAttachments`. Clean them up explicitly.
        newConversationViewModel.conversationViewModel?.cleanupPendingMediaAttachments()

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
}
