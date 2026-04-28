import Foundation
#if canImport(HomeKit) && os(iOS)
@preconcurrency import HomeKit
#endif

/// Write-side counterpart to `HomeDataSource`.
///
/// Two actions: `run_scene` (execute an action set) and `set_characteristic_value` (write a
/// single characteristic — "turn on this light", "set thermostat"). The characteristic
/// write coerces the supplied `value` argument to the characteristic's metadata format so
/// the agent can pass a plain string/bool/int and we do the bridging.
///
/// Requires the `com.apple.developer.homekit` entitlement. Without it,
/// `HMHomeManager.authorizationStatus` reports `.determined` without `.authorized` and all
/// invocations return `authorizationDenied`.
public final class HomeKitDataSink: DataSink, @unchecked Sendable {
    public let kind: ConnectionKind = .homeKit

    public init() {
        #if canImport(HomeKit) && os(iOS)
        self.state = StateBox()
        #endif
    }

    public func actionSchemas() async -> [ActionSchema] {
        HomeActionSchemas.all
    }

    #if canImport(HomeKit) && os(iOS)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        await state.authorizationStatus()
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        await state.primeAuthorization()
        return await authorizationStatus()
    }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        await state.invoke(invocation)
    }

    private actor StateBox {
        private var manager: HMHomeManager?
        private var delegate: Delegate?
        private var authorizationContinuation: CheckedContinuation<Void, Never>?

        func authorizationStatus() -> ConnectionAuthorizationStatus {
            let manager = manager ?? createManager()
            return HomeDataSource.map(manager.authorizationStatus)
        }

        func primeAuthorization() async {
            let manager = manager ?? createManager()
            if HomeDataSource.map(manager.authorizationStatus) != .notDetermined {
                return
            }
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
        }

        fileprivate func onHomesDidUpdate() {
            let continuation = authorizationContinuation
            authorizationContinuation = nil
            continuation?.resume()
        }

        func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
            switch invocation.action.name {
            case HomeActionSchemas.runScene.actionName:
                return await runScene(invocation)
            case HomeActionSchemas.setCharacteristicValue.actionName:
                return await setCharacteristicValue(invocation)
            default:
                return Self.makeResult(
                    for: invocation,
                    status: .unknownAction,
                    errorMessage: "HomeKit sink does not know action '\(invocation.action.name)'."
                )
            }
        }

        private func runScene(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
            let manager = manager ?? createManager()
            guard HomeDataSource.map(manager.authorizationStatus) == .authorized else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "HomeKit access is not granted.")
            }
            let args = invocation.action.arguments
            guard let home = resolveHome(manager: manager, homeId: args["homeId"]?.stringValue) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "No matching home found.")
            }
            let sceneResult = resolveScene(
                in: home,
                sceneId: args["sceneId"]?.stringValue,
                sceneName: args["sceneName"]?.stringValue
            )
            guard case .success(let scene) = sceneResult else {
                if case .failure(let message) = sceneResult {
                    return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: message)
                }
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Scene not found.")
            }

            do {
                try await home.executeActionSet(scene)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }
            return Self.makeResult(
                for: invocation,
                status: .success,
                result: ["sceneId": .string(scene.uniqueIdentifier.uuidString)]
            )
        }

        private func setCharacteristicValue(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
            let manager = manager ?? createManager()
            guard HomeDataSource.map(manager.authorizationStatus) == .authorized else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "HomeKit access is not granted.")
            }
            let args = invocation.action.arguments
            guard let home = resolveHome(manager: manager, homeId: args["homeId"]?.stringValue) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "No matching home found.")
            }
            guard let accessoryId = args["accessoryId"]?.stringValue else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'accessoryId'.")
            }
            guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == accessoryId }) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Accessory not found for id '\(accessoryId)'.")
            }
            guard let characteristicType = args["characteristicType"]?.stringValue else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'characteristicType'.")
            }
            guard let characteristic = Self.findCharacteristic(in: accessory, typeHint: characteristicType) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Accessory has no characteristic matching '\(characteristicType)'.")
            }
            guard let rawValue = args["value"] else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'value'.")
            }
            guard let coerced = Self.coerce(rawValue, for: characteristic) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not coerce 'value' to characteristic format.")
            }

            do {
                try await characteristic.writeValue(coerced)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }

            return Self.makeResult(
                for: invocation,
                status: .success,
                result: [
                    "accessoryId": .string(accessory.uniqueIdentifier.uuidString),
                    "characteristicId": .string(characteristic.uniqueIdentifier.uuidString),
                ]
            )
        }

        private func resolveHome(manager: HMHomeManager, homeId: String?) -> HMHome? {
            if let homeId {
                return manager.homes.first { $0.uniqueIdentifier.uuidString == homeId }
            }
            return manager.primaryHome ?? manager.homes.first
        }

        private func resolveScene(in home: HMHome, sceneId: String?, sceneName: String?) -> Resolution<HMActionSet> {
            if let sceneId {
                if let match = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == sceneId }) {
                    return .success(match)
                }
                return .failure("Scene not found for id '\(sceneId)'.")
            }
            if let sceneName {
                let matches = home.actionSets.filter { $0.name == sceneName }
                if matches.count == 1, let match = matches.first {
                    return .success(match)
                }
                if matches.isEmpty {
                    return .failure("No scene named '\(sceneName)'.")
                }
                return .failure("Multiple scenes named '\(sceneName)'; disambiguate by id.")
            }
            return .failure("Provide sceneId or sceneName.")
        }

        private enum Resolution<Value> {
            case success(Value)
            case failure(String)
        }

        private func createManager() -> HMHomeManager {
            let manager = HMHomeManager()
            let delegate = Delegate(state: self)
            manager.delegate = delegate
            self.manager = manager
            self.delegate = delegate
            return manager
        }

        private static func findCharacteristic(in accessory: HMAccessory, typeHint: String) -> HMCharacteristic? {
            let lower = typeHint.lowercased()
            let shortMap: [String: String] = [
                "power": HMCharacteristicTypePowerState,
                "on": HMCharacteristicTypePowerState,
                "brightness": HMCharacteristicTypeBrightness,
                "hue": HMCharacteristicTypeHue,
                "saturation": HMCharacteristicTypeSaturation,
                "targettemperature": HMCharacteristicTypeTargetTemperature,
                "targetheatingcooling": HMCharacteristicTypeTargetHeatingCooling,
                "lockstate": HMCharacteristicTypeTargetLockMechanismState,
                "lock": HMCharacteristicTypeTargetLockMechanismState,
            ]
            let target = shortMap[lower] ?? typeHint
            for service in accessory.services {
                for characteristic in service.characteristics where characteristic.characteristicType == target {
                    return characteristic
                }
            }
            return nil
        }

        private static func coerce(_ argument: ArgumentValue, for characteristic: HMCharacteristic) -> Any? {
            switch characteristic.metadata?.format ?? "" {
            case HMCharacteristicMetadataFormatBool:
                return coerceBool(argument)
            case HMCharacteristicMetadataFormatInt,
                HMCharacteristicMetadataFormatUInt8,
                HMCharacteristicMetadataFormatUInt16,
                HMCharacteristicMetadataFormatUInt32,
                HMCharacteristicMetadataFormatUInt64:
                return coerceInt(argument)
            case HMCharacteristicMetadataFormatFloat:
                return coerceDouble(argument)
            case HMCharacteristicMetadataFormatString:
                if case .string(let value) = argument { return value }
                return nil
            default:
                return coerceAny(argument)
            }
        }

        private static func coerceBool(_ argument: ArgumentValue) -> Any? {
            if case .bool(let value) = argument { return NSNumber(value: value) }
            if case .int(let value) = argument { return NSNumber(value: value != 0) }
            if case .string(let value) = argument {
                if ["true", "on", "1", "yes"].contains(value.lowercased()) { return NSNumber(value: true) }
                if ["false", "off", "0", "no"].contains(value.lowercased()) { return NSNumber(value: false) }
            }
            return nil
        }

        private static func coerceInt(_ argument: ArgumentValue) -> Any? {
            if case .int(let value) = argument { return NSNumber(value: value) }
            if case .double(let value) = argument {
                guard value.isFinite,
                      value >= Double(Int.min),
                      value <= Double(Int.max) else { return nil }
                return NSNumber(value: Int(value))
            }
            if case .string(let value) = argument, let parsed = Int(value) { return NSNumber(value: parsed) }
            return nil
        }

        private static func coerceDouble(_ argument: ArgumentValue) -> Any? {
            if case .double(let value) = argument { return NSNumber(value: value) }
            if case .int(let value) = argument { return NSNumber(value: Double(value)) }
            if case .string(let value) = argument, let parsed = Double(value) { return NSNumber(value: parsed) }
            return nil
        }

        private static func coerceAny(_ argument: ArgumentValue) -> Any? {
            if case .bool(let value) = argument { return NSNumber(value: value) }
            if case .int(let value) = argument { return NSNumber(value: value) }
            if case .double(let value) = argument { return NSNumber(value: value) }
            if case .string(let value) = argument { return value }
            return nil
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
    }

    private final class Delegate: NSObject, HMHomeManagerDelegate, @unchecked Sendable {
        weak var state: StateBox?

        init(state: StateBox) {
            self.state = state
        }

        func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
            let ref = state
            Task { await ref?.onHomesDidUpdate() }
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: .homeKit,
            actionName: invocation.action.name,
            status: .executionFailed,
            errorMessage: "HomeKit not available on this platform."
        )
    }
    #endif
}
