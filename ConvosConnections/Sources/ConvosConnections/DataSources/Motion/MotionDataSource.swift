import Foundation
#if canImport(CoreMotion) && os(iOS)
@preconcurrency import CoreMotion
#endif

/// Bridges the device's motion coprocessor classification into `ConvosConnections`.
///
/// Delivers high-level activity labels (stationary / walking / running / driving / cycling)
/// rather than raw accelerometer samples — that's the right grain for a conversation
/// payload. Each new activity classification emits one payload; steady-state stationary
/// periods produce nothing.
///
/// CMMotionActivityManager wakes the app intermittently for delivery while authorized;
/// it is *not* a true background-wake API like HealthKit observer queries.
public final class MotionDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .motion

    public init() {
        #if canImport(CoreMotion) && os(iOS)
        self.state = StateBox()
        #endif
    }

    #if canImport(CoreMotion) && os(iOS)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        return Self.map(CMMotionActivityManager.authorizationStatus())
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        // CoreMotion has no explicit request API — authorization is triggered implicitly
        // by the first query. Run a trivial one-shot to surface the prompt.
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        try await state.primeAuthorization()
        return await authorizationStatus()
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        return [
            AuthorizationDetail(
                identifier: "motion",
                displayName: "Motion & Fitness",
                status: status,
                note: nil
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        await state.start(emit: emit)
    }

    public func stop() async {
        await state.stop()
    }

    public func snapshotCurrent() async throws -> MotionPayload {
        try await state.snapshotCurrent()
    }

    static func map(_ status: CMAuthorizationStatus) -> ConnectionAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
    }

    static func map(activity: CMMotionActivity) -> MotionActivity {
        let type: MotionActivityType = {
            if activity.walking { return .walking }
            if activity.running { return .running }
            if activity.cycling { return .cycling }
            if activity.automotive { return .automotive }
            if activity.stationary { return .stationary }
            return .unknown
        }()
        let confidence: MotionConfidence = {
            switch activity.confidence {
            case .low: return .low
            case .medium: return .medium
            case .high: return .high
            @unknown default: return .low
            }
        }()
        return MotionActivity(type: type, confidence: confidence, startDate: activity.startDate)
    }

    static func summary(for activity: MotionActivity?) -> String {
        guard let activity else { return "No activity classified yet." }
        return "\(activity.type.rawValue.capitalized) (confidence: \(activity.confidence.rawValue))"
    }

    private actor StateBox {
        private let manager: CMMotionActivityManager = CMMotionActivityManager()
        private let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.qualityOfService = .utility
            return queue
        }()
        private var emitter: ConnectionPayloadEmitter?
        private var lastEmittedType: MotionActivityType?
        private var started: Bool = false

        func primeAuthorization() async throws {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.queryActivityStarting(from: Date(timeIntervalSinceNow: -60), to: Date(), to: queue) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume()
                }
            }
        }

        func start(emit: @escaping ConnectionPayloadEmitter) async {
            if started { return }
            self.emitter = emit
            started = true
            manager.startActivityUpdates(to: queue) { [weak self] activity in
                guard let activity else { return }
                let ref = self
                Task { await ref?.handleActivity(activity) }
            }
        }

        func stop() async {
            guard started else { return }
            manager.stopActivityUpdates()
            started = false
            emitter = nil
            lastEmittedType = nil
        }

        func snapshotCurrent() async throws -> MotionPayload {
            let latest: MotionActivity? = try await withCheckedThrowingContinuation { continuation in
                manager.queryActivityStarting(from: Date(timeIntervalSinceNow: -15 * 60), to: Date(), to: queue) { activities, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Map to Sendable MotionActivity inside the handler so the continuation
                    // only carries a Sendable value across isolation boundaries.
                    let mapped = activities?.last.map(MotionDataSource.map(activity:))
                    continuation.resume(returning: mapped)
                }
            }
            return MotionPayload(
                summary: MotionDataSource.summary(for: latest),
                activity: latest
            )
        }

        private func handleActivity(_ activity: CMMotionActivity) async {
            let mapped = MotionDataSource.map(activity: activity)
            if mapped.type == lastEmittedType { return }
            lastEmittedType = mapped.type
            guard let emitter else { return }
            let payload = MotionPayload(
                summary: MotionDataSource.summary(for: mapped),
                activity: mapped
            )
            emitter(ConnectionPayload(source: .motion, body: .motion(payload)))
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotCurrent() async throws -> MotionPayload {
        MotionPayload(summary: "Motion not available.", activity: nil)
    }
    #endif
}
