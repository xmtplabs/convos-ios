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
            Log.info("SleepingInboxMessageChecker: already running")
            return
        }
        isRunning = true
        Log.info("SleepingInboxMessageChecker: starting periodic checks (interval: \(checkInterval)s)")

        let notificationName = appLifecycle.willEnterForegroundNotification

        // Start foreground observer
        foregroundObserverTask = Task { [weak self] in
            let foregroundNotifications = NotificationCenter.default.notifications(named: notificationName)
            for await _ in foregroundNotifications {
                guard !Task.isCancelled else { break }
                Log.info("SleepingInboxMessageChecker: app entered foreground, checking now")
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
        Log.info("SleepingInboxMessageChecker: stopping periodic checks")
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
        // Capture lifecycle manager at the start to ensure consistent reference throughout
        guard let manager = lifecycleManager else {
            Log.debug("SleepingInboxMessageChecker: lifecycle manager deallocated, stopping checks")
            stopPeriodicChecks()
            return
        }

        // Get sleeping client IDs
        let sleepingClientIds = await manager.sleepingClientIds
        guard !sleepingClientIds.isEmpty else {
            Log.debug("SleepingInboxMessageChecker: no sleeping inboxes to check")
            return
        }

        Log.info("SleepingInboxMessageChecker: checking \(sleepingClientIds.count) sleeping inboxes")

        // Get conversation IDs for sleeping inboxes
        let conversationIdsByClient = try activityRepository.conversationIds(for: Array(sleepingClientIds))
        let allConversationIds = conversationIdsByClient.values.flatMap { $0 }

        guard !allConversationIds.isEmpty else {
            Log.debug("SleepingInboxMessageChecker: no conversations in sleeping inboxes")
            return
        }

        // Build API options and fetch newest message metadata
        let apiOptions = XMTPAPIOptionsBuilder.build(environment: environment)
        let metadata = try await xmtpStaticOperations.getNewestMessageMetadata(
            groupIds: Array(allConversationIds),
            api: apiOptions
        )

        // Get oldest awake inbox's lastActivity for comparison
        let awakeClientIds = await manager.awakeClientIds
        let oldestAwakeLastActivity = try findOldestAwakeLastActivity(awakeClientIds: awakeClientIds)

        // Check each sleeping inbox
        for clientId in sleepingClientIds {
            guard let conversationIds = conversationIdsByClient[clientId], !conversationIds.isEmpty else {
                continue
            }

            // Find the newest message time for this sleeping inbox
            let newestMessageNs = findNewestMessageTime(for: conversationIds, in: metadata)
            guard let newestNs = newestMessageNs else {
                continue
            }

            // Convert nanoseconds to Date for comparison
            let newestMessageDate = Date(timeIntervalSince1970: Double(newestNs) / 1_000_000_000)

            // If this sleeping inbox has newer messages than the oldest awake inbox, wake it
            if let threshold = oldestAwakeLastActivity, newestMessageDate > threshold {
                Log.info("SleepingInboxMessageChecker: waking inbox \(clientId) - has newer messages (\(newestMessageDate) > \(threshold))")

                do {
                    if let activity = try activityRepository.inboxActivity(for: clientId) {
                        _ = try await manager.wake(
                            clientId: clientId,
                            inboxId: activity.inboxId,
                            reason: .activityRanking
                        )
                    }
                } catch {
                    Log.error("SleepingInboxMessageChecker: failed to wake inbox \(clientId): \(error)")
                }
            }
        }
    }

    /// Finds the oldest lastActivity among awake inboxes
    private func findOldestAwakeLastActivity(awakeClientIds: Set<String>) throws -> Date? {
        guard !awakeClientIds.isEmpty else { return nil }

        let activities = try activityRepository.allInboxActivities()
        let awakeActivities = activities.filter { awakeClientIds.contains($0.clientId) }

        guard !awakeActivities.isEmpty else { return nil }

        // Return the oldest (minimum) lastActivity among awake inboxes
        // If an awake inbox has no lastActivity (nil), treat it as very old
        return awakeActivities.map { $0.lastActivity ?? .distantPast }.min()
    }

    /// Finds the newest message timestamp (in nanoseconds) for the given conversation IDs
    private func findNewestMessageTime(for conversationIds: [String], in metadata: [String: MessageMetadata]) -> Int64? {
        var newestNs: Int64?
        for conversationId in conversationIds {
            if let meta = metadata[conversationId] {
                if let current = newestNs {
                    if meta.createdNs > current {
                        newestNs = meta.createdNs
                    }
                } else {
                    newestNs = meta.createdNs
                }
            }
        }
        return newestNs
    }
}
