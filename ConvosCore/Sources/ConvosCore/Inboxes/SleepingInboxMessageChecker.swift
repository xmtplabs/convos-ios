import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// Periodically checks if sleeping inboxes have new messages that warrant waking them up
///
/// This actor monitors sleeping inboxes by using XMTP's static `getNewestMessageMetadata` method
/// to check for new messages without needing to wake the inbox's XMTP client. If a sleeping inbox
/// has newer messages than the oldest awake inbox, it may be promoted to awake status.
public actor SleepingInboxMessageChecker {
    /// Default interval between periodic checks (60 seconds in production)
    public static let defaultCheckInterval: TimeInterval = 60

    /// How long new inboxes with no activity are protected from eviction (multiple check cycles)
    /// In production: 60 * 12 = 720 seconds (12 minutes)
    public static let newInboxProtectionWindow: TimeInterval = defaultCheckInterval * 12

    private let checkInterval: TimeInterval
    private let environment: AppEnvironment
    private let activityRepository: any InboxActivityRepositoryProtocol
    private weak var lifecycleManager: (any InboxLifecycleManagerProtocol)?
    private let appLifecycle: any AppLifecycleProviding
    private let xmtpStaticOperations: SendableXMTPOperations

    private var periodicCheckTask: Task<Void, Never>?
    private var foregroundObserverTask: Task<Void, Never>?
    private var isRunning: Bool = false

    public init(
        checkInterval: TimeInterval = SleepingInboxMessageChecker.defaultCheckInterval,
        environment: AppEnvironment,
        activityRepository: any InboxActivityRepositoryProtocol,
        lifecycleManager: any InboxLifecycleManagerProtocol,
        appLifecycle: any AppLifecycleProviding,
        xmtpStaticOperations: any XMTPStaticOperations.Type = Client.self
    ) {
        self.checkInterval = checkInterval
        self.environment = environment
        self.activityRepository = activityRepository
        self.lifecycleManager = lifecycleManager
        self.appLifecycle = appLifecycle
        self.xmtpStaticOperations = SendableXMTPOperations(xmtpStaticOperations)
    }

    deinit {
        periodicCheckTask?.cancel()
        foregroundObserverTask?.cancel()
    }

    // MARK: - Public Methods

    /// Starts periodic checks for new messages in sleeping inboxes
    public func startPeriodicChecks() {
        guard !isRunning else {
            Log.debug("SleepingInboxMessageChecker: already running")
            return
        }
        isRunning = true
        Log.debug("SleepingInboxMessageChecker: starting periodic checks (interval: \(checkInterval)s)")

        let notificationName = appLifecycle.willEnterForegroundNotification

        // Start foreground observer
        foregroundObserverTask = Task { [weak self] in
            let foregroundNotifications = NotificationCenter.default.notifications(named: notificationName)
            for await _ in foregroundNotifications {
                guard !Task.isCancelled else { break }
                Log.debug("SleepingInboxMessageChecker: app entered foreground, checking now")
                await self?.checkNow()
            }
        }

        // Start periodic timer
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.checkInterval ?? 60))
                guard !Task.isCancelled else { break }
                await self?.checkNow()
            }
        }
    }

    /// Stops periodic checks
    public func stopPeriodicChecks() {
        Log.debug("SleepingInboxMessageChecker: stopping periodic checks")
        isRunning = false
        periodicCheckTask?.cancel()
        periodicCheckTask = nil
        foregroundObserverTask?.cancel()
        foregroundObserverTask = nil
    }

    /// Performs an immediate check for new messages in sleeping inboxes
    public func checkNow() async {
        do {
            try await performCheck()
        } catch {
            Log.error("SleepingInboxMessageChecker: check failed - \(error)")
        }
    }

    // MARK: - Private Methods

    private func performCheck() async throws {
        guard let lifecycleManager else {
            Log.debug("SleepingInboxMessageChecker: no lifecycle manager")
            return
        }

        let sleepingClientIds = await lifecycleManager.sleepingClientIds
        guard !sleepingClientIds.isEmpty else {
            Log.debug("SleepingInboxMessageChecker: no sleeping inboxes")
            return
        }

        // Fetch activities once before processing inboxes (avoids N+1 queries)
        let activities = try activityRepository.allInboxActivities()
        let activitiesByClientId = Dictionary(activities.map { ($0.clientId, $0) }, uniquingKeysWith: { _, latest in latest })

        // Get conversation IDs for sleeping inboxes
        let conversationIdsByClient = try activityRepository.conversationIds(for: Array(sleepingClientIds))

        // Collect all conversation IDs to batch the XMTP metadata request
        let allConversationIds = conversationIdsByClient.values.flatMap { $0 }
        guard !allConversationIds.isEmpty else {
            Log.debug("SleepingInboxMessageChecker: sleeping inboxes have no conversations")
            return
        }

        // Fetch newest message metadata for all conversations in one call
        let api = XMTPAPIOptionsBuilder.build(environment: environment)
        let metadata = try await xmtpStaticOperations.getNewestMessageMetadata(
            groupIds: Array(allConversationIds),
            api: api
        )

        // Check each sleeping inbox for messages newer than its sleep time
        for clientId in sleepingClientIds {
            guard let sleepTime = await lifecycleManager.sleepTime(for: clientId) else {
                Log.warning("SleepingInboxMessageChecker: no sleep time for \(clientId), skipping")
                continue
            }

            guard let conversationIds = conversationIdsByClient[clientId], !conversationIds.isEmpty else {
                continue
            }

            guard let newestMessageNs = findNewestMessageTime(for: conversationIds, in: metadata) else {
                continue
            }

            // Convert nanoseconds to Date for comparison
            let newestMessageDate = Date(timeIntervalSince1970: Double(newestMessageNs) / 1_000_000_000)

            // Only wake if the message arrived AFTER the inbox was put to sleep
            if newestMessageDate > sleepTime {
                Log.debug("SleepingInboxMessageChecker: inbox \(clientId) has new message (message: \(newestMessageDate), slept: \(sleepTime)), waking")

                // Get the inbox ID for this client (using pre-fetched dictionary)
                guard let activity = activitiesByClientId[clientId] else {
                    Log.error("SleepingInboxMessageChecker: no activity found for \(clientId)")
                    continue
                }

                do {
                    _ = try await lifecycleManager.wake(clientId: clientId, inboxId: activity.inboxId, reason: .activityRanking)
                } catch {
                    Log.error("SleepingInboxMessageChecker: failed to wake \(clientId): \(error)")
                }
            } else {
                Log.debug("SleepingInboxMessageChecker: inbox \(clientId) has no new messages since sleep (message: \(newestMessageDate), slept: \(sleepTime))")
            }
        }
    }

    /// Finds the newest message timestamp (in nanoseconds) for the given conversation IDs
    private func findNewestMessageTime(for conversationIds: [String], in metadata: [String: MessageMetadata]) -> Int64? {
        conversationIds.compactMap { metadata[$0]?.createdNs }.max()
    }
}
