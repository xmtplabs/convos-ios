import ConvosConnections
import Foundation
#if canImport(FamilyControls) && os(iOS)
@preconcurrency import FamilyControls
@preconcurrency import ManagedSettings
#endif

/// Bridges Family Controls / Screen Time authorization into `ConvosConnections`.
///
/// Requires the `com.apple.developer.family-controls` entitlement. Development builds can
/// be signed with automatic provisioning; App Store distribution needs the special
/// entitlement grant from Apple.
///
/// The source currently surfaces **authorization state only** — it does not emit usage
/// hours, categories, or specific-app metrics. Those signals come from Apple's isolated
/// Screen Time process, and surfacing them to the app requires a sibling
/// `DeviceActivityMonitor` extension target. That's tracked as follow-up work.
public final class ScreenTimeDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .screenTime

    public init() {
        #if canImport(FamilyControls) && os(iOS)
        self.state = StateBox()
        #endif
    }

    #if canImport(FamilyControls) && os(iOS)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        Self.map(AuthorizationCenter.shared.authorizationStatus)
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        return await authorizationStatus()
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        return [
            AuthorizationDetail(
                identifier: "family_controls",
                displayName: "Screen Time",
                status: status,
                note: "Usage data (hours in apps, categories) is not exposed directly to the app — a DeviceActivityMonitor extension is required. This source surfaces authorization state only."
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        await state.start(emit: emit)
    }

    public func stop() async {
        await state.stop()
    }

    public func snapshotCurrent() async -> ScreenTimePayload {
        await state.snapshotCurrent()
    }

    static func map(_ status: AuthorizationStatus) -> ConnectionAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .approved: return .authorized
        @unknown default: return .notDetermined
        }
    }

    static func buildPayload(authorized: Bool) -> ScreenTimePayload {
        let summary = authorized
            ? "Screen Time authorized. Usage data requires a DeviceActivityMonitor extension."
            : "Screen Time not authorized."
        return ScreenTimePayload(summary: summary, authorized: authorized)
    }

    private actor StateBox {
        private var emitter: ConnectionPayloadEmitter?

        func start(emit: @escaping ConnectionPayloadEmitter) async {
            self.emitter = emit
            emitCurrent()
        }

        func stop() async {
            emitter = nil
        }

        func snapshotCurrent() -> ScreenTimePayload {
            let status = AuthorizationCenter.shared.authorizationStatus
            return ScreenTimeDataSource.buildPayload(authorized: status == .approved)
        }

        private func emitCurrent() {
            guard let emitter else { return }
            let status = AuthorizationCenter.shared.authorizationStatus
            let payload = ScreenTimeDataSource.buildPayload(authorized: status == .approved)
            emitter(ConnectionPayload(source: .screenTime, body: .screenTime(payload)))
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotCurrent() async -> ScreenTimePayload {
        ScreenTimePayload(summary: "Screen Time not available.", authorized: false)
    }
    #endif
}
