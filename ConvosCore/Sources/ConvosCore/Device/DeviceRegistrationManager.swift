import Foundation

/// Protocol for device registration management
///
/// Allows for mocking in tests while providing the core device registration functionality.
public protocol DeviceRegistrationManagerProtocol: Actor {
    /// Starts observing push token changes. Should be called once on app launch.
    func startObservingPushTokenChanges()

    /// Stops observing push token changes. Called automatically on deinit.
    func stopObservingPushTokenChanges()

    /// Registers the device with the backend if needed (first time or token changed).
    /// Can be called multiple times safely - will skip if already registered with same token.
    func registerDeviceIfNeeded() async

    /// Clears the device registration state from UserDefaults.
    /// Call this on logout, "Delete all data", or when you want to force re-registration.
    static func clearRegistrationState(deviceInfo: any DeviceInfoProviding)

    /// Returns true if this device has been registered at least once.
    static func hasRegisteredDevice(deviceInfo: any DeviceInfoProviding) -> Bool
}

/// App-level manager for device registration with the backend.
///
/// Device registration is a device-level concern (not inbox-specific).
/// It uses Firebase AppCheck for authentication, not JWT tokens (which are inbox-specific).
///
/// This allows device registration to happen immediately on app launch,
/// without waiting for any inbox to be authorized.
///
/// The manager persists registration state in UserDefaults to avoid unnecessary re-registrations
/// across app launches and to detect when push tokens change.
///
/// The manager observes push token changes and automatically re-registers when the token arrives or changes.
public actor DeviceRegistrationManager: DeviceRegistrationManagerProtocol {
    // MARK: - Properties

    private let environment: AppEnvironment
    private let apiClient: any ConvosAPIClientProtocol
    private let platformProviders: PlatformProviders
    private var isRegistering: Bool = false
    nonisolated(unsafe) private var pushTokenObserver: NSObjectProtocol?

    public init(environment: AppEnvironment, platformProviders: PlatformProviders) {
        self.environment = environment
        self.platformProviders = platformProviders
        self.apiClient = ConvosAPIClientFactory.client(environment: environment)
    }

    deinit {
        if let observer = pushTokenObserver {
            NotificationCenter.default.removeObserver(observer)
            pushTokenObserver = nil
        }
    }

    // MARK: - Public API

    /// Starts observing push token changes. Should be called once on app launch.
    public func startObservingPushTokenChanges() {
        setupPushTokenObserver()
    }

    /// Stops observing push token changes. Called automatically on deinit.
    public func stopObservingPushTokenChanges() {
        removePushTokenObserver()
    }

    /// Registers the device with the backend if needed (first time or token changed).
    /// Can be called multiple times safely - will skip if already registered with same token.
    ///
    /// Uses Firebase AppCheck for authentication (device-level, not inbox-specific).
    /// This can be called immediately on app launch, without waiting for inbox authorization.
    ///
    /// Retry strategy: Will retry on every call if previous attempt failed (UserDefaults not updated on failure).
    /// This ensures eventual consistency even with intermittent network issues.
    ///
    /// Protected by isRegistering flag to prevent concurrent registration attempts.
    public func registerDeviceIfNeeded() async {
        if case .tests = environment {
            Log.info("Skipping device registration for tests environment...")
            return
        }

        guard !isRegistering else {
            Log.info("Registration already in progress, skipping")
            return
        }

        isRegistering = true
        defer { isRegistering = false }

        let deviceId = platformProviders.deviceInfo.deviceIdentifier
        let pushToken = platformProviders.pushNotificationRegistrar.token

        // Get last registered token from UserDefaults (persisted across app launches)
        let lastTokenKey = "lastRegisteredDevicePushToken_\(deviceId)"
        let hasRegisteredKey = "hasRegisteredDevice_\(deviceId)"

        let lastToken = UserDefaults.standard.string(forKey: lastTokenKey)
        let hasEverRegistered = UserDefaults.standard.bool(forKey: hasRegisteredKey)

        // Register if:
        // 1. Never registered this device before (important for v1→v2 migration)
        // 2. Push token has changed (including nil → token and token → nil)
        let shouldRegister = !hasEverRegistered || lastToken != pushToken

        guard shouldRegister else {
            Log.info("Device already registered with this token")
            return
        }

        let reason = !hasEverRegistered ? "first time" : "token changed"

        do {
            Log.info("Registering device (\(reason), token: \(pushToken != nil ? "present" : "nil"))")

            try await apiClient.registerDevice(deviceId: deviceId, pushToken: pushToken)

            // Always persist registration state after successful registration
            // This prevents unnecessary re-registration attempts when token is nil
            UserDefaults.standard.set(true, forKey: hasRegisteredKey)

            if let pushToken = pushToken {
                UserDefaults.standard.set(pushToken, forKey: lastTokenKey)
                Log.info("Successfully registered device with push token")
            } else {
                // Clear lastToken when successfully registering with nil token
                // This ensures we don't keep retrying with nil on every launch
                UserDefaults.standard.removeObject(forKey: lastTokenKey)
                Log.info("Successfully registered device without push token")
            }
        } catch {
            Log.error("Failed to register device: \(error). Will retry on next attempt.")
        }
    }

    /// Clears the device registration state from UserDefaults.
    /// Call this on logout, "Delete all data", or when you want to force re-registration.
    public static func clearRegistrationState(deviceInfo: any DeviceInfoProviding) {
        let deviceId = deviceInfo.deviceIdentifier
        UserDefaults.standard.removeObject(forKey: "lastRegisteredDevicePushToken_\(deviceId)")
        UserDefaults.standard.removeObject(forKey: "hasRegisteredDevice_\(deviceId)")
        Log.info("Cleared device registration state")
    }

    /// Returns true if this device has been registered at least once.
    public static func hasRegisteredDevice(deviceInfo: any DeviceInfoProviding) -> Bool {
        let deviceId = deviceInfo.deviceIdentifier
        return UserDefaults.standard.bool(forKey: "hasRegisteredDevice_\(deviceId)")
    }

    // MARK: - Push Token Observer

    private func setupPushTokenObserver() {
        guard pushTokenObserver == nil else { return }

        Log.info("DeviceRegistrationManager: Setting up push token observer...")
        pushTokenObserver = NotificationCenter.default.addObserver(
            forName: .convosPushTokenDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handlePushTokenChange()
            }
        }
    }

    private func removePushTokenObserver() {
        guard let observer = pushTokenObserver else {
            return
        }
        NotificationCenter.default.removeObserver(observer)
        pushTokenObserver = nil
        Log.info("DeviceRegistrationManager: Removed push token observer")
    }

    private func handlePushTokenChange() async {
        Log.info("DeviceRegistrationManager: Push token changed, re-registering device...")
        await registerDeviceIfNeeded()
    }
}
