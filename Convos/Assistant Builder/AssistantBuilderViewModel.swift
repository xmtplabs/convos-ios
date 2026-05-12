import Combine
import ConvosCore
import ConvosLogging
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AssistantBuilderViewModel: Identifiable {
    enum Phase: Equatable {
        case bootstrap
        case focus
        case stopped
    }

    let session: any SessionManagerProtocol

    private(set) var phase: Phase = .bootstrap
    private(set) var conversationId: String?
    private(set) var invite: Invite?
    private(set) var conversation: Conversation?
    private(set) var focusSession: DBFocusSession?
    private(set) var liveBubbles: [DBLiveBubble] = []

    /// Flips true when the user taps "Start chatting" on the session-ended
    /// canvas. Drives the final crossfade into the standard ConversationView.
    private(set) var didTransitionToConversation: Bool = false

    /// Drives the QR / share card overlay (mirrors ConversationViewModel).
    var presentingShareView: Bool = false

    /// Two-way bound from `LiveBubbleEditor`. Each set fans out to the
    /// streaming publisher (debounced) so peers see the snapshot.
    var draftText: String = "" {
        didSet {
            guard draftText != oldValue else { return }
            // A newline-containing snapshot is a transient clear trigger from
            // the editor — it'll be stripped + cleared on the next tick. Don't
            // bump the activity timer or fan it out to peers, otherwise the
            // bubble briefly grows out of compact mode just to collapse again.
            guard !draftText.contains("\n") else { return }
            updateBubbleBoundary(oldText: oldValue, newText: draftText)
            publisher?.publish(text: draftText)
            recomputeLocalActivity()
            recomputeReadByMembers()
        }
    }

    /// True briefly after a non-self member's live text empties out, so the
    /// region layout can give that member's "final phrase" a moment of focus
    /// before snapping back to user-only.
    private(set) var othersRecentlyStopped: Bool = false

    /// Per-side typing state for the bottom region's two slots (me + the
    /// loudest "other"). Drives the bubble-size + dot-variant decision in
    /// `FocusRegionLayout` — the active typer gets the Full slot, the idle
    /// side collapses to the compact dot pill.
    enum BubbleActivity: Equatable {
        case empty   // no text typed
        case active  // text changed within the rest window (~1.5 s)
        case resting // text present but no recent change
    }

    private(set) var localActivity: BubbleActivity = .empty
    private(set) var othersActivity: BubbleActivity = .empty

    /// Non-agent, non-self members whose latest read receipt is newer than the
    /// timestamp at which the local user's current bubble started. Drives the
    /// "Read" row under the user's bubble. Empty when the user hasn't typed
    /// anything (no current bubble to mark).
    private(set) var readByMembers: [ConversationMember] = []

    /// Stable session id for the focus mode lifecycle of this builder instance.
    /// Sent on every FocusModeControl so receivers can correlate start/stop pairs.
    let focusSessionId: String = UUID().uuidString

    @ObservationIgnored
    private var dismissAction: DismissAction?

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []

    @ObservationIgnored
    private var messagingService: AnyMessagingService?

    @ObservationIgnored
    private var conversationStateManager: (any ConversationStateManagerProtocol)?

    @ObservationIgnored
    private var inboxAcquisitionTask: Task<Void, Never>?

    @ObservationIgnored
    private var stateObservationTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasSentInitialFocusStart: Bool = false

    /// Once we've shipped a promotion `.start`, don't send another one for the
    /// same session — even if the local writer hasn't yet applied it through
    /// the publisher loop. Without this latch, every member-list change re-fires
    /// the promotion before our own message round-trips back.
    @ObservationIgnored
    private var hasSentPromotionForSession: String?

    @ObservationIgnored
    private var publisher: FocusSessionPublisher?

    @ObservationIgnored
    private var lastOtherTextWasNonEmpty: Bool = false

    @ObservationIgnored
    private var othersRecentlyStoppedTimer: Task<Void, Never>?

    @ObservationIgnored
    private var localRestTask: Task<Void, Never>?

    @ObservationIgnored
    private var othersRestTask: Task<Void, Never>?

    @ObservationIgnored
    private var readReceiptWriter: (any ReadReceiptWriterProtocol)?

    @ObservationIgnored
    private var readReceipts: [ReadReceiptEntry] = []

    /// Wall-clock nanoseconds when the local user's current bubble began
    /// (empty → non-empty draft). Reset to nil when the bubble clears. Used as
    /// the boundary for which incoming read receipts count as "for this bubble".
    @ObservationIgnored
    private var currentBubbleStartedAtNs: Int64?

    /// Rate-limits read-receipt sends so a long-typed peer snapshot doesn't
    /// fire one per repaint. Receipts are conversation-scoped, not message-
    /// scoped, so a single send carries the timestamp forward.
    @ObservationIgnored
    private var lastFocusReadReceiptSentAt: Date?

    /// Pending auto-clear timer. The local user's draft is wiped 3 s after
    /// it has been read by at least one human peer — gives them a moment to
    /// see the "Read" indicator before the bubble resets for the next thought.
    @ObservationIgnored
    private var autoClearTask: Task<Void, Never>?

    private static let autoClearAfterReadWindow: UInt64 = 3_000_000_000

    /// Window after the last text change before a bubble is treated as
    /// "resting" — the active typer wins the Full slot during this window,
    /// then yields it to whoever else is still typing.
    private static let restWindow: UInt64 = 1_500_000_000

    /// Set when this builder was opened to *join* an existing assistant builder
    /// convo (via the clipboard.fill toolbar button). Bootstrapping then runs
    /// `joinConversation(inviteCode:)` instead of creating a new convo, and
    /// the initial-`.start` / promotion sends are skipped (the creator already
    /// owns the focus session lifecycle — joiners just consume state via the
    /// `ConversationSnapshot` rebroadcast).
    @ObservationIgnored
    private let joiningInviteCode: String?

    init(session: any SessionManagerProtocol, joiningInviteCode: String? = nil) {
        self.session = session
        self.joiningInviteCode = joiningInviteCode
        bootstrapConversation()
    }

    func setDismissAction(_ dismiss: DismissAction) {
        self.dismissAction = dismiss
    }

    func dismiss() {
        cleanUp()
        dismissAction?()
    }

    func copyInviteToPasteboard() -> Bool {
        guard let invite, !invite.urlSlug.isEmpty else { return false }
        UIPasteboard.general.string = invite.urlSlug
        return true
    }

    /// Copies the full invite URL — used by the toolbar add-to-conversation menu.
    /// Mirrors `ConversationViewModel.copyInviteLink()`.
    func copyInviteLink() {
        guard let invite, !invite.inviteURLString.isEmpty else { return }
        UIPasteboard.general.string = invite.inviteURLString
    }

    // MARK: - Live bubble derivations

    var focusedMemberLiveText: String {
        guard let focusedInboxId = focusSession?.focusedInboxId else { return "" }
        return liveBubbles.first(where: { $0.senderInboxId == focusedInboxId })?.text ?? ""
    }

    var othersLiveText: String {
        let myInboxId = currentInboxId
        let focusedInboxId = focusSession?.focusedInboxId
        return liveBubbles
            .filter { $0.senderInboxId != myInboxId && $0.senderInboxId != focusedInboxId }
            .map(\.text)
            .first(where: { !$0.isEmpty }) ?? ""
    }

    var othersAreTyping: Bool {
        !othersLiveText.isEmpty
    }

    /// First non-self, non-focused member whose live bubble currently has
    /// text — drives the avatar shown beside the compact "others typing"
    /// dot pill. Falls back to nil if no other has text right now.
    var firstActiveOtherMember: ConversationMember? {
        let myInboxId = currentInboxId
        let focusedInboxId = focusSession?.focusedInboxId
        let activeOtherInboxId = liveBubbles
            .first(where: {
                !$0.text.isEmpty && $0.senderInboxId != myInboxId && $0.senderInboxId != focusedInboxId
            })?
            .senderInboxId
        guard let activeOtherInboxId,
              let conversation else { return nil }
        return conversation.members.first(where: { $0.profile.inboxId == activeOtherInboxId })
    }

    /// The focused assistant member, once known. Carries both the profile
    /// (avatar/name) and the agentVerification (drives the verified badge
    /// styling on the avatar). Stays nil until an *agent* joins — peer
    /// humans (e.g. someone who joined via the clipboard.fill button) must
    /// not show up in the indicator slot. Once we have an agent, the value
    /// is sticky: brief nil emissions from the conversation/focus-session
    /// publishers (which happen during streaming-text sync as their
    /// underlying GRDB rows get rewritten) won't cause the avatar's verified
    /// ring or the focused bubble's lava bg to flash off and back on.
    private(set) var assistantMember: ConversationMember?

    /// Pure derivation — what `assistantMember` *would* be right now from
    /// the latest conversation + focus-session snapshot. Used to refresh
    /// the sticky value with newer member data (e.g. assistant pushes a
    /// ProfileUpdate with a new name) without re-introducing nil flickers.
    private var derivedAssistantMember: ConversationMember? {
        guard let conversation else { return nil }
        let focusedInboxId = focusSession?.focusedInboxId
        if let focusedInboxId,
           let member = conversation.members.first(where: { $0.profile.inboxId == focusedInboxId }) {
            return member
        }
        return conversation.members.first(where: { !$0.isCurrentUser && $0.isAgent })
    }

    private func refreshAssistantMember() {
        guard let derived = derivedAssistantMember else { return }
        if assistantMember != derived {
            assistantMember = derived
        }
    }

    var assistantProfile: Profile? {
        assistantMember?.profile
    }

    var assistantVerification: AgentVerification {
        assistantMember?.agentVerification ?? .unverified
    }

    /// True between session bootstrap and the agent being promoted into the
    /// focus slot — drives the "Waiting for assistant…" placeholder in the
    /// focused-member bubble. Flips false the moment the focus session row
    /// gains a non-nil `focusedInboxId`.
    var isWaitingForAssistant: Bool {
        focusSession?.focusedInboxId == nil
    }

    /// Display name for the indicator. Empty until the assistant has set its
    /// own profile name; UI falls back to "New assistant" placeholder.
    var assistantName: String {
        assistantProfile?.name ?? ""
    }

    /// Send a StreamingClear so peers blank our bubble (after their 600ms
    /// readability delay), and clear our local draft immediately.
    func handleReturnPressed() {
        publisher?.clear()
        draftText = ""
    }

    /// User tapped "Start chatting" on the session-ended canvas. Triggers
    /// the final transition into the standard ConversationView.
    func startChattingTapped() {
        didTransitionToConversation = true
    }

    /// Debug helper for the prototype: locally end the focus session by
    /// sending FocusModeControl(.stop). In production this would be sent
    /// by the assistant when it decides it has enough information.
    func debugEndFocusSession() {
        guard let conversationId,
              let messagingService,
              let focusSession else { return }
        let payload = FocusModeControl(
            state: .stop,
            focusedInboxId: nil,
            sessionId: focusSession.sessionId
        )
        Task {
            do {
                try await messagingService.sendFocusModeControl(payload, for: conversationId)
            } catch {
                Log.error("Failed sending FocusModeControl(.stop): \(error.localizedDescription)")
            }
        }
    }

    private var currentInboxId: String {
        switch messagingService?.state {
        case .authorized(let inboxId):
            return inboxId
        default:
            return ""
        }
    }

    // MARK: - Bootstrap

    private func bootstrapConversation() {
        inboxAcquisitionTask = Task { [weak self] in
            guard let self else { return }
            let (messagingService, existingId) = await session.prepareNewConversation()
            guard !Task.isCancelled else { return }
            self.messagingService = messagingService
            self.readReceiptWriter = messagingService.readReceiptWriter()

            let stateManager: any ConversationStateManagerProtocol
            if let existingId {
                stateManager = messagingService.conversationStateManager(for: existingId)
            } else {
                stateManager = messagingService.conversationStateManager()
            }
            self.conversationStateManager = stateManager

            observeStateManager(stateManager)
            if let inviteCode = self.joiningInviteCode {
                await joinGroupConversation(via: stateManager, inviteCode: inviteCode)
            } else {
                await createGroupConversation(via: stateManager)
            }
        }
    }

    private func joinGroupConversation(
        via stateManager: any ConversationStateManagerProtocol,
        inviteCode: String
    ) async {
        do {
            try await stateManager.joinConversation(inviteCode: inviteCode)
        } catch {
            Log.error("Failed to join assistant builder conversation: \(error.localizedDescription)")
        }
    }

    private func createGroupConversation(via stateManager: any ConversationStateManagerProtocol) async {
        do {
            try await stateManager.createConversation()
        } catch {
            Log.error("Failed to create assistant builder conversation: \(error.localizedDescription)")
        }
    }

    private func observeStateManager(_ stateManager: any ConversationStateManagerProtocol) {
        stateObservationTask = Task { [weak self, stateManager] in
            for await state in stateManager.stateSequence {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.handle(stateManagerState: state)
            }
        }
    }

    @MainActor
    private func handle(stateManagerState state: ConversationStateMachine.State) async {
        switch state {
        case .ready(let result):
            guard conversationId != result.conversationId else { return }
            conversationId = result.conversationId
            attachRepositories(for: result.conversationId)
            await sendInitialFocusStartIfNeeded(for: result.conversationId)
        default:
            break
        }
    }

    private func attachRepositories(for conversationId: String) {
        let inviteRepo = session.inviteRepository(for: conversationId)
        inviteRepo.invitePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invite in
                self?.invite = invite
            }
            .store(in: &cancellables)

        let conversationRepo = session.conversationRepository(for: conversationId)
        conversationRepo.conversationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversation in
                guard let self else { return }
                self.conversation = conversation
                self.refreshAssistantMember()
                self.handleConversationMembersChanged()
                self.recomputeReadByMembers()
            }
            .store(in: &cancellables)

        let focusRepo = session.focusSessionRepository(for: conversationId)
        focusRepo.latestSessionPublisher(in: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.handleFocusSessionChanged(to: session)
            }
            .store(in: &cancellables)

        let messagesRepo = session.messagesRepository(for: conversationId)
        messagesRepo.conversationMessagesResultPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                self?.readReceipts = result.readReceipts
                self?.recomputeReadByMembers()
            }
            .store(in: &cancellables)
    }

    private func sendInitialFocusStartIfNeeded(for conversationId: String) async {
        // Joiners don't own the focus session lifecycle — the creator already
        // sent `.start` and the `ConversationSnapshot` rebroadcast catches us
        // up. Re-sending would double-write the session and confuse promotion.
        guard joiningInviteCode == nil else { return }
        guard !hasSentInitialFocusStart, let messagingService else { return }
        hasSentInitialFocusStart = true
        let payload = FocusModeControl(
            state: .start,
            focusedInboxId: nil,
            sessionId: focusSessionId
        )
        do {
            try await messagingService.sendFocusModeControl(payload, for: conversationId)
        } catch {
            Log.error("Failed sending initial FocusModeControl(.start): \(error.localizedDescription)")
        }
    }

    private func handleConversationMembersChanged() {
        guard joiningInviteCode == nil else {
            Log.info("[FocusPromotion] skipped: this client is a joiner")
            return
        }
        guard let conversation,
              let conversationId,
              let messagingService else {
            Log.info("[FocusPromotion] skipped: conversation/id/service not ready")
            return
        }
        guard let firstAgent = conversation.members.first(where: {
            !$0.isCurrentUser && $0.isAgent
        }) else {
            let memberSummary = conversation.members
                .map { "\($0.profile.inboxId.prefix(8))(isAgent=\($0.isAgent),isMe=\($0.isCurrentUser))" }
                .joined(separator: ",")
            Log.info("[FocusPromotion] skipped: no eligible agent in members [\(memberSummary)]")
            return
        }
        guard let focusSession else {
            Log.info("[FocusPromotion] skipped: no focusSession yet (agent=\(firstAgent.profile.inboxId.prefix(8)))")
            return
        }
        guard focusSession.state == .started else {
            Log.info("[FocusPromotion] skipped: focusSession.state=\(focusSession.state)")
            return
        }
        guard focusSession.focusedInboxId == nil else {
            Log.info("[FocusPromotion] skipped: already focused on \(String(focusSession.focusedInboxId?.prefix(8) ?? "?"))")
            return
        }
        guard hasSentPromotionForSession != focusSession.sessionId else {
            Log.info("[FocusPromotion] skipped: already sent promotion for session \(focusSession.sessionId)")
            return
        }
        hasSentPromotionForSession = focusSession.sessionId
        let payload = FocusModeControl(
            state: .start,
            focusedInboxId: firstAgent.profile.inboxId,
            sessionId: focusSession.sessionId
        )
        Log.info("[FocusPromotion] sending .start to agent \(firstAgent.profile.inboxId.prefix(8)) for session \(focusSession.sessionId)")
        Task {
            do {
                try await messagingService.sendFocusModeControl(payload, for: conversationId)
                Log.info("[FocusPromotion] .start delivered for session \(focusSession.sessionId)")
            } catch {
                Log.error("[FocusPromotion] failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleFocusSessionChanged(to session: DBFocusSession?) {
        focusSession = session
        refreshAssistantMember()
        guard let session else { return }
        switch session.state {
        case .started:
            phase = (session.focusedInboxId == nil) ? .bootstrap : .focus
            ensurePublisherExists(for: session)
            ensureLiveBubblesSubscription(for: session.sessionId)
            // Trigger possible promotion now that we have a session row to fill.
            handleConversationMembersChanged()
        case .stopped:
            phase = .stopped
        }
    }

    private func ensurePublisherExists(for session: DBFocusSession) {
        guard publisher == nil,
              let conversationId,
              let messagingService else { return }
        publisher = FocusSessionPublisher(
            messagingService: messagingService,
            conversationId: conversationId,
            sessionId: session.sessionId,
            senderInboxId: currentInboxId
        )
    }

    private func ensureLiveBubblesSubscription(for sessionId: String) {
        // Re-subscribe if the session id changed.
        let alreadySubscribedKey = "liveBubbles:\(sessionId)"
        guard activeBubbleSubscription != alreadySubscribedKey else { return }
        activeBubbleSubscription = alreadySubscribedKey

        guard let conversationId else { return }
        let repo = session.focusSessionRepository(for: conversationId)
        repo.liveBubblesPublisher(sessionId: sessionId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bubbles in
                self?.applyLiveBubbles(bubbles)
            }
            .store(in: &cancellables)
    }

    @ObservationIgnored
    private var activeBubbleSubscription: String?

    private func applyLiveBubbles(_ bubbles: [DBLiveBubble]) {
        liveBubbles = bubbles
        let othersHasText = !othersLiveText.isEmpty
        if lastOtherTextWasNonEmpty && !othersHasText {
            othersRecentlyStopped = true
            othersRecentlyStoppedTimer?.cancel()
            othersRecentlyStoppedTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.othersRecentlyStopped = false }
            }
        } else if othersHasText {
            othersRecentlyStopped = false
            othersRecentlyStoppedTimer?.cancel()
        }
        lastOtherTextWasNonEmpty = othersHasText
        recomputeOthersActivity()
    }

    private func recomputeLocalActivity() {
        localRestTask?.cancel()
        if draftText.isEmpty {
            localActivity = .empty
            scheduleAutoClearIfNeeded()
            return
        }
        localActivity = .active
        scheduleAutoClearIfNeeded()
        localRestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.restWindow)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.draftText.isEmpty else { return }
                self.localActivity = .resting
                self.scheduleAutoClearIfNeeded()
            }
        }
    }

    private func recomputeOthersActivity() {
        othersRestTask?.cancel()
        if othersLiveText.isEmpty {
            othersActivity = .empty
            return
        }
        othersActivity = .active
        othersRestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.restWindow)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.othersLiveText.isEmpty else { return }
                self.othersActivity = .resting
            }
        }
    }

    // MARK: - Read receipts

    private func updateBubbleBoundary(oldText: String, newText: String) {
        if oldText.isEmpty && !newText.isEmpty {
            currentBubbleStartedAtNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        } else if !oldText.isEmpty && newText.isEmpty {
            currentBubbleStartedAtNs = nil
        }
    }

    private func recomputeReadByMembers() {
        guard let conversation, let currentBubbleStartedAtNs else {
            readByMembers = []
            scheduleAutoClearIfNeeded()
            return
        }
        let myInboxId = currentInboxId
        let qualifyingInboxIds: Set<String> = Set(
            readReceipts
                .filter { $0.readAtNs > currentBubbleStartedAtNs && $0.inboxId != myInboxId }
                .map(\.inboxId)
        )
        readByMembers = conversation.members.filter { member in
            !member.isCurrentUser
                && !member.isAgent
                && qualifyingInboxIds.contains(member.profile.inboxId)
        }
        scheduleAutoClearIfNeeded()
    }

    /// Schedules — or cancels and reschedules — the auto-clear timer based
    /// on the current draft, read state, and local activity. We only auto-
    /// clear when the draft has been read by a peer *and* the user isn't
    /// currently typing (so we don't yank text out from under them).
    private func scheduleAutoClearIfNeeded() {
        autoClearTask?.cancel()
        autoClearTask = nil
        guard !draftText.isEmpty,
              !readByMembers.isEmpty,
              localActivity != .active else { return }
        autoClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoClearAfterReadWindow)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      !self.draftText.isEmpty,
                      !self.readByMembers.isEmpty,
                      self.localActivity != .active else { return }
                self.handleReturnPressed()
            }
        }
    }

    /// Sent by `FocusModeView` after another member's full bubble has been
    /// visible for ≥1.5 seconds. Conversation-scoped (not message-scoped) —
    /// the timestamp on the receipt is what other clients use to filter.
    func sendFocusReadReceiptIfNeeded() {
        guard let conversationId, let readReceiptWriter else { return }
        let minimumInterval: TimeInterval = 1.0
        if let last = lastFocusReadReceiptSentAt,
           Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        lastFocusReadReceiptSentAt = Date()
        Task {
            do {
                try await readReceiptWriter.sendReadReceipt(for: conversationId)
            } catch {
                Log.warning("Failed to send focus read receipt: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cleanup

    private func cleanUp() {
        inboxAcquisitionTask?.cancel()
        stateObservationTask?.cancel()
        cancellables.removeAll()
    }
}
