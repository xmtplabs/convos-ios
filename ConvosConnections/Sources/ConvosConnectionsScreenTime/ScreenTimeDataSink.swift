import ConvosConnections
import Foundation
#if canImport(FamilyControls) && os(iOS)
@preconcurrency import FamilyControls
@preconcurrency import ManagedSettings
#endif

/// Write-side counterpart to `ScreenTimeDataSource`.
///
/// Lives in the opt-in `ConvosConnectionsScreenTime` product because it depends on
/// `com.apple.developer.family-controls`, which requires Apple distribution approval.
///
/// Two actions:
/// - `apply_selection` — shield the set of apps/categories/web domains encoded in a
///   previously-persisted `FamilyActivitySelection` JSON bundle (produced by a user
///   `FamilyActivityPicker` interaction).
/// - `clear_shields` — remove all restrictions from the default `ManagedSettingsStore`.
public final class ScreenTimeDataSink: DataSink, @unchecked Sendable {
    public let kind: ConnectionKind = .screenTime

    public init() {}

    public func actionSchemas() async -> [ActionSchema] {
        ScreenTimeActionSchemas.all
    }

    #if canImport(FamilyControls) && os(iOS)
    private let managedSettingsStore: ManagedSettingsStore = ManagedSettingsStore()

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        ScreenTimeDataSource.map(AuthorizationCenter.shared.authorizationStatus)
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        return await authorizationStatus()
    }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        switch invocation.action.name {
        case ScreenTimeActionSchemas.applySelection.actionName:
            return applySelection(invocation)
        case ScreenTimeActionSchemas.clearShields.actionName:
            return clearShields(invocation)
        default:
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "ScreenTime sink does not know action '\(invocation.action.name)'."
            )
        }
    }

    private func applySelection(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Screen Time (Family Controls) is not approved.")
        }
        guard let base64 = invocation.action.arguments["selectionData"]?.stringValue,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing or invalid 'selectionData' (must be Base64-encoded JSON).")
        }

        let selection: FamilyActivitySelection
        do {
            selection = try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not decode FamilyActivitySelection: \(error.localizedDescription).")
        }

        managedSettingsStore.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        managedSettingsStore.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        managedSettingsStore.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens

        return Self.makeResult(
            for: invocation,
            status: .success,
            result: [
                "applicationCount": .int(selection.applicationTokens.count),
                "categoryCount": .int(selection.categoryTokens.count),
                "webDomainCount": .int(selection.webDomainTokens.count),
            ]
        )
    }

    private func clearShields(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Screen Time (Family Controls) is not approved.")
        }
        managedSettingsStore.shield.applications = nil
        managedSettingsStore.shield.applicationCategories = nil
        managedSettingsStore.shield.webDomains = nil
        return Self.makeResult(for: invocation, status: .success)
    }

    private static func makeResult(
        for invocation: ConnectionInvocation,
        status: ConnectionInvocationResult.Status,
        errorMessage: String? = nil,
        result: [String: ArgumentValue] = [:]
    ) -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: status,
            result: result,
            errorMessage: errorMessage
        )
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: .screenTime,
            actionName: invocation.action.name,
            status: .executionFailed,
            errorMessage: "FamilyControls not available on this platform."
        )
    }
    #endif
}
