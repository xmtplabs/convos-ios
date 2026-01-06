import Foundation

/// Configuration object containing platform-specific provider implementations.
///
/// This struct enables dependency injection of platform-specific functionality.
///
/// Usage in iOS app:
/// ```swift
/// import ConvosCore
/// import ConvosCoreiOS
///
/// let convos = ConvosClient.client(
///     environment: .production,
///     platformProviders: .iOS
/// )
/// ```
///
/// Usage in tests:
/// ```swift
/// let mockProviders = PlatformProviders(
///     appLifecycle: MockAppLifecycleProvider(),
///     deviceInfo: MockDeviceInfo(),
///     pushNotificationRegistrar: MockPushNotificationRegistrar()
/// )
/// let convos = ConvosClient.client(
///     environment: .tests,
///     platformProviders: mockProviders
/// )
/// ```
public struct PlatformProviders: Sendable {
    /// Provider for app lifecycle events (foreground, background, active states)
    public let appLifecycle: any AppLifecycleProviding

    /// Provider for device information (device identifier, OS string)
    public let deviceInfo: any DeviceInfoProviding

    /// Provider for push notification token management
    public let pushNotificationRegistrar: any PushNotificationRegistrarProtocol

    public init(
        appLifecycle: any AppLifecycleProviding,
        deviceInfo: any DeviceInfoProviding,
        pushNotificationRegistrar: any PushNotificationRegistrarProtocol
    ) {
        self.appLifecycle = appLifecycle
        self.deviceInfo = deviceInfo
        self.pushNotificationRegistrar = pushNotificationRegistrar
    }
}

// MARK: - Test/Mock Support

/// Mock app lifecycle provider for testing
public final class MockAppLifecycleProvider: AppLifecycleProviding, @unchecked Sendable {
    public let didEnterBackgroundNotification: Notification.Name
    public let willEnterForegroundNotification: Notification.Name
    public let didBecomeActiveNotification: Notification.Name

    private var _currentState: AppState

    @MainActor
    public var currentState: AppState { _currentState }

    public init(
        currentState: AppState = .active,
        didEnterBackgroundNotification: Notification.Name = Notification.Name("MockDidEnterBackground"),
        willEnterForegroundNotification: Notification.Name = Notification.Name("MockWillEnterForeground"),
        didBecomeActiveNotification: Notification.Name = Notification.Name("MockDidBecomeActive")
    ) {
        self._currentState = currentState
        self.didEnterBackgroundNotification = didEnterBackgroundNotification
        self.willEnterForegroundNotification = willEnterForegroundNotification
        self.didBecomeActiveNotification = didBecomeActiveNotification
    }

    public func setCurrentState(_ state: AppState) {
        _currentState = state
    }
}

/// Mock device info provider for testing
public final class MockDeviceInfoProvider: DeviceInfoProviding, Sendable {
    public let identifierForVendor: String?
    public let fallbackIdentifier: String
    public let deviceIdentifier: String
    public let osString: String

    public init(
        identifierForVendor: String? = "mock-vendor-id",
        fallbackIdentifier: String = "mock-fallback-id",
        deviceIdentifier: String = "mock-device-id",
        osString: String = "mock"
    ) {
        self.identifierForVendor = identifierForVendor
        self.fallbackIdentifier = fallbackIdentifier
        self.deviceIdentifier = deviceIdentifier
        self.osString = osString
    }
}

/// Mock push notification registrar for testing
public final class MockPushNotificationRegistrarProvider: PushNotificationRegistrarProtocol, @unchecked Sendable {
    private var _token: String?

    public var token: String? { _token }

    public init(token: String? = nil) {
        self._token = token
    }

    public func save(token: String) {
        _token = token
    }

    public func requestNotificationAuthorizationIfNeeded() async -> Bool {
        true
    }

    public func setToken(_ token: String?) {
        _token = token
    }
}

// MARK: - Test Configuration

extension PlatformProviders {
    /// Creates a mock configuration for testing
    public static var mock: PlatformProviders {
        PlatformProviders(
            appLifecycle: MockAppLifecycleProvider(),
            deviceInfo: MockDeviceInfoProvider(),
            pushNotificationRegistrar: MockPushNotificationRegistrarProvider()
        )
    }
}
