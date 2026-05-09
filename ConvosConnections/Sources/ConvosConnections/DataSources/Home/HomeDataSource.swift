import Foundation
#if canImport(HomeKit) && os(iOS)
@preconcurrency import HomeKit
#endif

/// Bridges the user's HomeKit topology into `ConvosConnections`.
///
/// Requires the `com.apple.developer.homekit` entitlement *and* the `NSHomeKitUsageDescription`
/// key in `Info.plist`. Without the entitlement, `authorizationStatus()` returns `.denied`
/// because HMHomeManager cannot be instantiated successfully.
///
/// Observation scope: home list changes. Accessory-level state changes (lock open, light
/// on/off, temperature) are intentionally not surfaced — that granularity pushes the agent
/// into command-and-control territory that a context-feeder shouldn't try to cover.
public final class HomeDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .homeKit

    public init() {
        #if canImport(HomeKit) && os(iOS)
        self.state = StateBox()
        #endif
    }

    #if canImport(HomeKit) && os(iOS)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        await state.authorizationStatus()
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        // HMHomeManager prompts implicitly on its first access. Trigger it by creating the
        // manager and waiting for the "homes didUpdate" callback, which fires once
        // authorization is resolved.
        await state.primeAuthorization()
        return await authorizationStatus()
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        return [
            AuthorizationDetail(
                identifier: "home_kit",
                displayName: "Home Data",
                status: status,
                note: "Requires the HomeKit entitlement in the app's provisioning profile. If the toggle won't turn on, the app isn't provisioned for HomeKit."
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        await state.start(emit: emit)
    }

    public func stop() async {
        await state.stop()
    }

    public func snapshotCurrent() async -> HomePayload {
        await state.snapshotCurrent()
    }

    static func map(_ status: HMHomeManagerAuthorizationStatus) -> ConnectionAuthorizationStatus {
        if status.contains(.restricted) { return .denied }
        if status.contains(.authorized) { return .authorized }
        if status.contains(.determined) { return .denied }
        return .notDetermined
    }

    static func buildPayload(homes: [HMHome]) -> HomePayload {
        let summaries = homes.map { home in
            HomeSummary(
                id: home.uniqueIdentifier.uuidString,
                name: home.name,
                isPrimary: home.isPrimary,
                roomCount: home.rooms.count,
                accessoryCount: home.accessories.count
            )
        }
        let accessoryTotal = summaries.reduce(0) { $0 + $1.accessoryCount }
        let summaryText: String = {
            if homes.isEmpty {
                return "No HomeKit homes configured."
            }
            return "\(homes.count) home\(homes.count == 1 ? "" : "s"), \(accessoryTotal) accessor\(accessoryTotal == 1 ? "y" : "ies") total."
        }()
        return HomePayload(summary: summaryText, homes: summaries)
    }

    private actor StateBox {
        private var manager: HMHomeManager?
        private var delegate: Delegate?
        private var emitter: ConnectionPayloadEmitter?
        /// Waiters keyed by a per-call UUID so a cancelled task only resumes its own
        /// continuation, leaving any concurrent callers waiting for the real callback.
        private var authorizationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        private var hasEmittedInitial: Bool = false

        func authorizationStatus() -> ConnectionAuthorizationStatus {
            let manager = manager ?? createManager()
            return HomeDataSource.map(manager.authorizationStatus)
        }

        func primeAuthorization() async {
            let manager = manager ?? createManager()
            if HomeDataSource.map(manager.authorizationStatus) != .notDetermined {
                return
            }
            let waiterId = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    authorizationWaiters[waiterId] = continuation
                }
            } onCancel: {
                // Strong capture: `CheckedContinuation` traps if released without being
                // resumed, so the actor must outlive any pending waiter even when the
                // owning host has dropped its reference.
                Task { await self.cancelAuthorizationWaiter(id: waiterId) }
            }
        }

        private func cancelAuthorizationWaiter(id: UUID) {
            authorizationWaiters.removeValue(forKey: id)?.resume()
        }

        func start(emit: @escaping ConnectionPayloadEmitter) async {
            self.emitter = emit
            let manager = manager ?? createManager()
            hasEmittedInitial = false
            emitCurrent(homes: manager.homes)
        }

        func stop() async {
            emitter = nil
        }

        func snapshotCurrent() -> HomePayload {
            let manager = manager ?? createManager()
            return HomeDataSource.buildPayload(homes: manager.homes)
        }

        fileprivate func onHomesDidUpdate(homes: [HMHome]) {
            let waiters = authorizationWaiters
            authorizationWaiters = [:]
            for waiter in waiters.values { waiter.resume() }

            emitCurrent(homes: homes)
        }

        fileprivate func onHomeListChange(homes: [HMHome]) {
            emitCurrent(homes: homes)
        }

        private func emitCurrent(homes: [HMHome]) {
            guard let emitter else { return }
            let payload = HomeDataSource.buildPayload(homes: homes)
            emitter(ConnectionPayload(source: .homeKit, body: .homeKit(payload)))
            hasEmittedInitial = true
        }

        private func createManager() -> HMHomeManager {
            let manager = HMHomeManager()
            let delegate = Delegate(state: self)
            manager.delegate = delegate
            self.manager = manager
            self.delegate = delegate
            return manager
        }
    }

    private final class Delegate: NSObject, HMHomeManagerDelegate, @unchecked Sendable {
        weak var state: StateBox?

        init(state: StateBox) {
            self.state = state
        }

        func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
            let ref = state
            let box = UncheckedSendableBox(manager.homes)
            Task { await ref?.onHomesDidUpdate(homes: box.value) }
        }

        func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
            let ref = state
            let box = UncheckedSendableBox(manager.homes)
            Task { await ref?.onHomeListChange(homes: box.value) }
        }

        func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
            let ref = state
            let box = UncheckedSendableBox(manager.homes)
            Task { await ref?.onHomeListChange(homes: box.value) }
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotCurrent() async -> HomePayload {
        HomePayload(summary: "HomeKit not available.", homes: [])
    }
    #endif
}
