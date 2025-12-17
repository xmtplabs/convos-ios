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

    /// Wakes an inbox, evicting LRU inbox if at capacity.
    /// This is the primary method for waking inboxes from user-initiated operations
    /// (opening a conversation, push notification) that must succeed even at capacity.
    func wake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol

    func sleep(clientId: String) async
    func getService(for clientId: String) -> (any MessagingServiceProtocol)?
    func getOrWake(clientId: String, inboxId: String) async throws -> any MessagingServiceProtocol
    func isAwake(clientId: String) -> Bool
    func isSleeping(clientId: String) -> Bool
    func rebalance(activeClientId: String?) async
    func initializeOnAppLaunch() async
    func stopAll() async
}

public actor InboxLifecycleManager: InboxLifecycleManagerProtocol {
    public let maxAwakeInboxes: Int

    private var awakeInboxes: [String: any MessagingServiceProtocol] = [:]
    private var _sleepingClientIds: Set<String> = []

    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let identityStore: any KeychainIdentityStoreProtocol
    private let environment: AppEnvironment
    private let platformProviders: PlatformProviders
    private let activityRepository: any InboxActivityRepositoryProtocol
    private let pendingInviteRepository: any PendingInviteRepositoryProtocol

    public var awakeClientIds: Set<String> {
        Set(awakeInboxes.keys)
    }

    public var sleepingClientIds: Set<String> {
        _sleepingClientIds
    }

    public var pendingInviteClientIds: Set<String> {
        (try? pendingInviteRepository.clientIdsWithPendingInvites()) ?? []
    }

    public init(
        maxAwakeInboxes: Int = 20,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        identityStore: any KeychainIdentityStoreProtocol,
        environment: AppEnvironment,
        platformProviders: PlatformProviders,
        activityRepository: (any InboxActivityRepositoryProtocol)? = nil,
        pendingInviteRepository: (any PendingInviteRepositoryProtocol)? = nil
    ) {
        self.maxAwakeInboxes = maxAwakeInboxes
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.identityStore = identityStore
        self.environment = environment
        self.platformProviders = platformProviders
        self.activityRepository = activityRepository ?? InboxActivityRepository(databaseReader: databaseReader)
        self.pendingInviteRepository = pendingInviteRepository ?? PendingInviteRepository(databaseReader: databaseReader)
    }

    public func wake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol {
        if let existing = awakeInboxes[clientId] {
            Log.info("Inbox already awake: \(clientId)")
            return existing
        }

        // If at capacity, free a slot first
        if awakeInboxes.count >= maxAwakeInboxes {
            Log.info("At capacity (\(awakeInboxes.count)/\(maxAwakeInboxes)), evicting LRU for \(clientId)")
            await sleepLeastRecentlyUsed(excluding: [clientId])
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

        let hasPendingInvite = (try? pendingInviteRepository.hasPendingInvites(clientId: clientId)) ?? false
        let currentAwakeCount = awakeInboxes.count

        // Check capacity - pending invites are always allowed, others must have room
        if !hasPendingInvite && currentAwakeCount >= maxAwakeInboxes {
            Log.warning("Cannot wake inbox \(clientId): at capacity (\(currentAwakeCount)/\(maxAwakeInboxes))")
            throw InboxLifecycleError.wakeCapacityExceeded
        }

        let service = createMessagingService(inboxId: inboxId, clientId: clientId)
        awakeInboxes[clientId] = service
        _sleepingClientIds.remove(clientId)

        Log.info("Inbox woke successfully: \(clientId), total awake: \(awakeInboxes.count)")
        return service
    }

    public func sleep(clientId: String) async {
        guard let service = awakeInboxes.removeValue(forKey: clientId) else {
            Log.info("Inbox not awake, cannot sleep: \(clientId)")
            return
        }

        let hasPendingInvite = (try? pendingInviteRepository.hasPendingInvites(clientId: clientId)) ?? false
        if hasPendingInvite {
            Log.warning("Cannot sleep inbox with pending invite: \(clientId), keeping awake")
            awakeInboxes[clientId] = service
            return
        }

        Log.info("Sleeping inbox: \(clientId)")
        service.stop()
        _sleepingClientIds.insert(clientId)
        Log.info("Inbox slept successfully: \(clientId), total awake: \(awakeInboxes.count)")
    }

    public func getService(for clientId: String) -> (any MessagingServiceProtocol)? {
        awakeInboxes[clientId]
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

    public func rebalance(activeClientId: String? = nil) async {
        do {
            let allActivities = try activityRepository.allInboxActivities()
            let pendingInviteIds = pendingInviteClientIds

            // Build set of protected client IDs (pending invites + currently active)
            var protectedClientIds = pendingInviteIds
            if let activeClientId {
                protectedClientIds.insert(activeClientId)
            }

            // Determine which inboxes should be awake:
            // 1. All protected inboxes (active + pending invites)
            // 2. Top N by lastActivity (excluding protected, since they're already counted)
            var shouldBeAwake = protectedClientIds

            let nonProtectedActivities = allActivities.filter { !protectedClientIds.contains($0.clientId) }
            let slotsForNonProtected = max(0, maxAwakeInboxes - protectedClientIds.count)
            let topNonProtected = nonProtectedActivities.prefix(slotsForNonProtected)
            for activity in topNonProtected {
                shouldBeAwake.insert(activity.clientId)
            }

            // Sleep inboxes FIRST - free capacity before waking
            let awakeClientIdsCopy = Set(awakeInboxes.keys)
            for clientId in awakeClientIdsCopy where !shouldBeAwake.contains(clientId) {
                Log.info("Rebalance: sleeping inbox \(clientId)")
                await sleep(clientId: clientId)
            }

            // Wake inboxes that should be awake but aren't
            for activity in allActivities where shouldBeAwake.contains(activity.clientId) {
                if !awakeInboxes.keys.contains(activity.clientId) {
                    // Ensure capacity before waking (safety check)
                    if awakeInboxes.count >= maxAwakeInboxes {
                        Log.info("Rebalance: at capacity, sleeping LRU before waking \(activity.clientId)")
                        await sleepLeastRecentlyUsed(excluding: shouldBeAwake)
                    }
                    Log.info("Rebalance: waking inbox \(activity.clientId) (lastActivity: \(activity.lastActivity?.description ?? "nil"))")
                    _ = try await attemptWake(clientId: activity.clientId, inboxId: activity.inboxId, reason: .activityRanking)
                }
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
            let pendingInviteIds = pendingInviteClientIds

            Log.info("Found \(allActivities.count) inboxes, \(pendingInviteIds.count) with pending invites")

            var wokenCount = 0
            for activity in allActivities {
                let hasPendingInvite = pendingInviteIds.contains(activity.clientId)

                if hasPendingInvite || wokenCount < maxAwakeInboxes {
                    do {
                        _ = try await attemptWake(
                            clientId: activity.clientId,
                            inboxId: activity.inboxId,
                            reason: hasPendingInvite ? .pendingInvite : .appLaunch
                        )
                        if !hasPendingInvite {
                            wokenCount += 1
                        }
                    } catch {
                        Log.error("Failed to wake inbox \(activity.clientId): \(error)")
                    }
                } else {
                    _sleepingClientIds.insert(activity.clientId)
                    Log.info("Inbox marked as sleeping: \(activity.clientId)")
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
            service.stop()
        }

        awakeInboxes.removeAll()
        _sleepingClientIds.removeAll()

        Log.info("All inboxes stopped")
    }

    private func sleepLeastRecentlyUsed(excluding excludedClientIds: Set<String>) async {
        do {
            let activities = try activityRepository.allInboxActivities()

            let sleepCandidate = activities.last { activity in
                awakeInboxes[activity.clientId] != nil &&
                !excludedClientIds.contains(activity.clientId) &&
                !pendingInviteClientIds.contains(activity.clientId)
            }

            if let candidate = sleepCandidate {
                Log.info("LRU sleep candidate: \(candidate.clientId), lastActivity: \(candidate.lastActivity?.description ?? "nil")")
                await sleep(clientId: candidate.clientId)
            } else {
                Log.warning("No suitable inbox found for LRU sleep")
            }
        } catch {
            Log.error("Failed to find LRU inbox: \(error)")
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
