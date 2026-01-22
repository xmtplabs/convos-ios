import Foundation
import GRDB

public enum WakeReason: String, Sendable {
    case userInteraction
    case pushNotification
    case activityRanking
    case pendingInvite
    case appLaunch
}

public enum InboxLifecycleError: Error {
    case inboxNotFound(clientId: String)
    case identityNotFound(clientId: String)
    case wakeCapacityExceeded
    case alreadyAwake(clientId: String)
    case alreadySleeping(clientId: String)
}

public protocol InboxLifecycleManagerProtocol: Actor {
    var maxAwakeInboxes: Int { get }
    var awakeClientIds: Set<String> { get }
    var sleepingClientIds: Set<String> { get }
    var pendingInviteClientIds: Set<String> { get }

    /// Returns when an inbox was put to sleep, or nil if not sleeping
    func sleepTime(for clientId: String) -> Date?

    /// The currently active client ID (e.g., the inbox whose conversation is currently open).
    /// This inbox is protected from being put to sleep during rebalance.
    var activeClientId: String? { get }

    /// Sets the active client ID. Pass nil when no conversation is active.
    func setActiveClientId(_ clientId: String?)

    /// Creates a new inbox using the unused inbox cache, registering it with the lifecycle manager.
    /// All inbox creation goes through this method. The new inbox is automatically set as active.
    func createNewInbox() async -> any MessagingServiceProtocol

    /// Wakes an inbox, evicting LRU inbox if at capacity.
    /// This is the primary method for waking inboxes from user-initiated operations
    /// (opening a conversation, push notification) that must succeed even at capacity.
    func wake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol

    func sleep(clientId: String) async

    /// Force-removes an inbox from all tracking without pending invite checks.
    /// Used during deletion when the service has already been stopped.
    func forceRemove(clientId: String) async

    /// Returns an existing awake service, or creates a new one without tracking it.
    /// Used for deletion when we need a service but don't want to add it to the awake set.
    func getOrCreateService(clientId: String, inboxId: String) -> any MessagingServiceProtocol

    func getOrWake(clientId: String, inboxId: String) async throws -> any MessagingServiceProtocol
    func isAwake(clientId: String) -> Bool
    func isSleeping(clientId: String) -> Bool
    func rebalance() async
    func initializeOnAppLaunch() async
    func stopAll() async
    func prepareUnusedInboxIfNeeded() async
    func clearUnusedInbox() async
}

public actor InboxLifecycleManager: InboxLifecycleManagerProtocol {
    public let maxAwakeInboxes: Int

    private var awakeInboxes: [String: any MessagingServiceProtocol] = [:]
    private var _sleepingClientIds: Set<String> = []
    private var _sleepTimes: [String: Date] = [:]
    private var _activeClientId: String?

    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let identityStore: any KeychainIdentityStoreProtocol
    private let environment: AppEnvironment
    private let platformProviders: PlatformProviders
    private let activityRepository: any InboxActivityRepositoryProtocol
    private let pendingInviteRepository: any PendingInviteRepositoryProtocol
    private let unusedInboxCache: any UnusedInboxCacheProtocol

    public var awakeClientIds: Set<String> {
        Set(awakeInboxes.keys)
    }

    public var sleepingClientIds: Set<String> {
        _sleepingClientIds
    }

    public var pendingInviteClientIds: Set<String> {
        (try? pendingInviteRepository.clientIdsWithPendingInvites()) ?? []
    }

    public var activeClientId: String? {
        _activeClientId
    }

    public func sleepTime(for clientId: String) -> Date? {
        _sleepTimes[clientId]
    }

    public init(
        maxAwakeInboxes: Int = 25,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        identityStore: any KeychainIdentityStoreProtocol,
        environment: AppEnvironment,
        platformProviders: PlatformProviders,
        activityRepository: (any InboxActivityRepositoryProtocol)? = nil,
        pendingInviteRepository: (any PendingInviteRepositoryProtocol)? = nil,
        unusedInboxCache: (any UnusedInboxCacheProtocol)? = nil
    ) {
        self.maxAwakeInboxes = maxAwakeInboxes
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.identityStore = identityStore
        self.environment = environment
        self.platformProviders = platformProviders
        self.activityRepository = activityRepository ?? InboxActivityRepository(databaseReader: databaseReader)
        self.pendingInviteRepository = pendingInviteRepository ?? PendingInviteRepository(databaseReader: databaseReader)
        self.unusedInboxCache = unusedInboxCache ?? UnusedInboxCache(
            identityStore: identityStore,
            platformProviders: platformProviders
        )
    }

    public func setActiveClientId(_ clientId: String?) {
        _activeClientId = clientId
        Log.info("Active client ID set to: \(clientId ?? "nil")")
    }

    public func createNewInbox() async -> any MessagingServiceProtocol {
        // If at capacity, free a slot first
        if awakeInboxes.count >= maxAwakeInboxes {
            Log.info("At capacity (\(awakeInboxes.count)/\(maxAwakeInboxes)), evicting LRU for new inbox")
            let freed = await sleepLeastRecentlyUsed(excluding: [])
            if !freed {
                Log.warning("Could not free capacity for new inbox - will exceed maxAwakeInboxes")
            }
        }

        let messagingService = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )

        // Register the inbox and set it as active
        let clientId = messagingService.clientId
        awakeInboxes[clientId] = messagingService
        _sleepingClientIds.remove(clientId)
        _activeClientId = clientId
        Log.info("New inbox created, registered, and set as active: \(clientId), total awake: \(awakeInboxes.count)")

        return messagingService
    }

    public func wake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol {
        if let existing = awakeInboxes[clientId] {
            Log.info("Inbox already awake: \(clientId)")
            return existing
        }

        // If at capacity, free a slot first
        if awakeInboxes.count >= maxAwakeInboxes {
            Log.info("At capacity (\(awakeInboxes.count)/\(maxAwakeInboxes)), evicting LRU for \(clientId)")
            let freed = await sleepLeastRecentlyUsed(excluding: [clientId])
            if !freed {
                Log.warning("Could not free capacity - attemptWake may fail unless inbox has pending invite")
            }
        }

        return try await attemptWake(clientId: clientId, inboxId: inboxId, reason: reason)
    }

    /// Internal wake that throws if at capacity
    private func attemptWake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol {
        Log.info("Attempting wake for inbox clientId: \(clientId), reason: \(reason.rawValue)")

        if let existing = awakeInboxes[clientId] {
            Log.info("Inbox already awake: \(clientId)")
            return existing
        }

        // Fail open: if pending invite check fails, assume true to preserve privilege
        let hasPendingInvite: Bool
        do {
            hasPendingInvite = try pendingInviteRepository.hasPendingInvites(clientId: clientId)
        } catch {
            Log.error("Failed to check pending invites for \(clientId), assuming true: \(error)")
            hasPendingInvite = true
        }
        let currentAwakeCount = awakeInboxes.count

        // Check capacity - pending invites are always allowed, others must have room
        if !hasPendingInvite && currentAwakeCount >= maxAwakeInboxes {
            Log.warning("Cannot wake inbox \(clientId): at capacity (\(currentAwakeCount)/\(maxAwakeInboxes))")
            throw InboxLifecycleError.wakeCapacityExceeded
        }

        let service = createMessagingService(inboxId: inboxId, clientId: clientId)
        awakeInboxes[clientId] = service
        _sleepingClientIds.remove(clientId)
        _sleepTimes.removeValue(forKey: clientId)

        Log.info("Inbox woke successfully: \(clientId), total awake: \(awakeInboxes.count)")
        return service
    }

    public func sleep(clientId: String) async {
        guard let service = awakeInboxes.removeValue(forKey: clientId) else {
            Log.info("Inbox not awake, cannot sleep: \(clientId)")
            return
        }

        // Fail open: if pending invite check fails, assume true to preserve privilege
        let hasPendingInvite: Bool
        do {
            hasPendingInvite = try pendingInviteRepository.hasPendingInvites(clientId: clientId)
        } catch {
            Log.error("Failed to check pending invites for \(clientId), assuming true: \(error)")
            hasPendingInvite = true
        }
        if hasPendingInvite {
            Log.warning("Cannot sleep inbox with pending invite: \(clientId), keeping awake")
            awakeInboxes[clientId] = service
            return
        }

        Log.info("Sleeping inbox: \(clientId)")
        let sleepTime = Date()
        await service.stop()
        _sleepingClientIds.insert(clientId)
        _sleepTimes[clientId] = sleepTime
        Log.info("Inbox slept successfully: \(clientId), total awake: \(awakeInboxes.count)")
    }

    public func forceRemove(clientId: String) async {
        if let service = awakeInboxes.removeValue(forKey: clientId) {
            await service.stop()
            Log.info("Stopped and force removed inbox from tracking: \(clientId)")
        } else {
            Log.info("Force removed inbox from tracking (was not awake): \(clientId)")
        }
        _sleepingClientIds.remove(clientId)
        _sleepTimes.removeValue(forKey: clientId)
        if _activeClientId == clientId {
            _activeClientId = nil
        }
    }

    public func getOrCreateService(clientId: String, inboxId: String) -> any MessagingServiceProtocol {
        // Return existing awake service if available
        if let existing = awakeInboxes[clientId] {
            return existing
        }
        // Create a new service without adding to tracking (used for deletion)
        return createMessagingService(inboxId: inboxId, clientId: clientId)
    }

    public func getOrWake(clientId: String, inboxId: String) async throws -> any MessagingServiceProtocol {
        if let existing = awakeInboxes[clientId] {
            return existing
        }
        return try await wake(clientId: clientId, inboxId: inboxId, reason: .userInteraction)
    }

    public func isAwake(clientId: String) -> Bool {
        awakeInboxes[clientId] != nil
    }

    public func isSleeping(clientId: String) -> Bool {
        _sleepingClientIds.contains(clientId)
    }

    public func rebalance() async {
        do {
            let allActivities = try activityRepository.allInboxActivities()
            let pendingInviteIds = pendingInviteClientIds

            // Filter out unused inboxes - they're reserved for createNewInbox() and should not be
            // woken by rebalance. This prevents dual-tracking where the same inbox exists in both
            // awakeInboxes and unusedInboxCache.
            var eligibleActivities: [InboxActivity] = []
            for activity in allActivities {
                let isUnused = await unusedInboxCache.isUnusedInbox(activity.inboxId)
                if !isUnused {
                    eligibleActivities.append(activity)
                } else {
                    Log.info("Rebalance: skipping unused inbox \(activity.clientId)")
                }
            }

            // Build set of protected client IDs (pending invites + currently active)
            var protectedClientIds = pendingInviteIds
            if let activeClientId = _activeClientId {
                protectedClientIds.insert(activeClientId)
            }

            // Determine which inboxes should be awake:
            // 1. All protected inboxes (active + pending invites)
            // 2. Top N by lastActivity (excluding protected, since they're already counted)
            var shouldBeAwake = protectedClientIds

            let nonProtectedActivities = eligibleActivities.filter { !protectedClientIds.contains($0.clientId) }
            let slotsForNonProtected = max(0, maxAwakeInboxes - protectedClientIds.count)
            let topNonProtected = nonProtectedActivities.prefix(slotsForNonProtected)
            for activity in topNonProtected {
                shouldBeAwake.insert(activity.clientId)
            }

            // Sleep inboxes - free capacity before waking
            let awakeClientIdsCopy = Set(awakeInboxes.keys)
            for clientId in awakeClientIdsCopy where !shouldBeAwake.contains(clientId) {
                Log.info("Rebalance: sleeping inbox \(clientId)")
                await sleep(clientId: clientId)
            }

            // Wake inboxes that should be awake but aren't
            var failedWakeCount = 0
            for activity in eligibleActivities where shouldBeAwake.contains(activity.clientId) {
                if !awakeInboxes.keys.contains(activity.clientId) {
                    do {
                        Log.info("Rebalance: waking inbox \(activity.clientId) (lastActivity: \(activity.lastActivity?.description ?? "nil"))")
                        _ = try await attemptWake(clientId: activity.clientId, inboxId: activity.inboxId, reason: .activityRanking)
                    } catch {
                        failedWakeCount += 1
                        Log.error("Rebalance: failed to wake inbox \(activity.clientId): \(error)")
                    }
                }
            }

            if failedWakeCount > 0 {
                Log.warning("Rebalance: \(failedWakeCount) inbox(es) failed to wake")
            }
            Log.info("Rebalance complete: \(awakeInboxes.count) awake, \(_sleepingClientIds.count) sleeping")
        } catch {
            Log.error("Rebalance failed: \(error)")
        }
    }

    public func initializeOnAppLaunch() async {
        Log.info("Initializing InboxLifecycleManager on app launch")

        do {
            let allActivities = try activityRepository.allInboxActivities()
            let allPendingInvites = try pendingInviteRepository.allPendingInvites()
            let activityClientIds = Set(allActivities.map { $0.clientId })

            Log.info("Found \(allActivities.count) inboxes with activity, \(allPendingInvites.count) with pending invites")

            // wake inboxes from activity records
            for activity in allActivities {
                let hasPendingInvite = allPendingInvites.contains { $0.clientId == activity.clientId && $0.hasPendingInvites }

                // Pending invites always wake (can exceed maxAwakeInboxes)
                // Regular inboxes only wake if we haven't hit capacity
                if hasPendingInvite || awakeInboxes.count < maxAwakeInboxes {
                    do {
                        _ = try await attemptWake(
                            clientId: activity.clientId,
                            inboxId: activity.inboxId,
                            reason: hasPendingInvite ? .pendingInvite : .appLaunch
                        )
                    } catch {
                        Log.error("Failed to wake inbox \(activity.clientId): \(error)")
                    }
                } else {
                    _sleepingClientIds.insert(activity.clientId)
                    Log.info("Inbox marked as sleeping: \(activity.clientId)")
                }
            }

            // wake pending invite inboxes that have no activity record
            for pendingInvite in allPendingInvites where pendingInvite.hasPendingInvites {
                let clientId = pendingInvite.clientId
                let inboxId = pendingInvite.inboxId
                if !activityClientIds.contains(clientId) && !awakeInboxes.keys.contains(clientId) {
                    Log.info("Waking pending invite inbox with no activity record: \(clientId)")
                    do {
                        _ = try await attemptWake(
                            clientId: clientId,
                            inboxId: inboxId,
                            reason: .pendingInvite
                        )
                    } catch {
                        Log.error("Failed to wake pending invite inbox \(clientId): \(error)")
                    }
                }
            }

            Log.info("App launch initialization complete: \(awakeInboxes.count) awake, \(_sleepingClientIds.count) sleeping")
        } catch {
            Log.error("Failed to initialize InboxLifecycleManager: \(error)")
        }
    }

    public func stopAll() async {
        Log.info("Stopping all inboxes")

        for (clientId, service) in awakeInboxes {
            Log.info("Stopping inbox: \(clientId)")
            await service.stop()
        }

        awakeInboxes.removeAll()
        _sleepingClientIds.removeAll()
        _sleepTimes.removeAll()
        _activeClientId = nil

        Log.info("All inboxes stopped")
    }

    public func prepareUnusedInboxIfNeeded() async {
        await unusedInboxCache.prepareUnusedInboxIfNeeded(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
    }

    public func clearUnusedInbox() async {
        await unusedInboxCache.clearUnusedInboxFromKeychain()
    }

    /// Attempts to sleep the least recently used inbox to free capacity.
    ///
    /// Inboxes with `nil` lastActivity are treated as "newly created" and protected from eviction
    /// for `newInboxProtectionWindow` seconds after creation. This prevents newly created inboxes
    /// (which haven't received messages yet) from being immediately evicted.
    ///
    /// Note: This differs from `SleepingInboxMessageChecker.findOldestAwakeLastActivity()` which
    /// treats `nil` lastActivity as `.distantPast` for message timestamp comparisons. The semantics
    /// differ because eviction protection (here) and message recency comparison (there) have
    /// different goals.
    ///
    /// - Returns: `true` if an inbox was successfully slept, `false` otherwise.
    @discardableResult
    private func sleepLeastRecentlyUsed(excluding excludedClientIds: Set<String>) async -> Bool {
        do {
            let activities = try activityRepository.allInboxActivities()
            let newInboxThreshold = Date().addingTimeInterval(-SleepingInboxMessageChecker.newInboxProtectionWindow)

            let sleepCandidate = activities.last { activity in
                awakeInboxes[activity.clientId] != nil &&
                !excludedClientIds.contains(activity.clientId) &&
                !pendingInviteClientIds.contains(activity.clientId) &&
                activity.clientId != _activeClientId &&
                (activity.lastActivity != nil || activity.createdAt < newInboxThreshold)
            }

            if let candidate = sleepCandidate {
                Log.info("LRU sleep candidate: \(candidate.clientId), lastActivity: \(candidate.lastActivity?.description ?? "nil"), createdAt: \(candidate.createdAt)")
                await sleep(clientId: candidate.clientId)
                return true
            } else {
                Log.warning("No suitable inbox found for LRU sleep - all inboxes are protected, active, have pending invites, or are newly created")
                return false
            }
        } catch {
            Log.error("Failed to find LRU inbox: \(error)")
            return false
        }
    }

    private func createMessagingService(inboxId: String, clientId: String) -> any MessagingServiceProtocol {
        MessagingService.authorizedMessagingService(
            for: inboxId,
            clientId: clientId,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            startsStreamingServices: true,
            platformProviders: platformProviders
        )
    }
}
