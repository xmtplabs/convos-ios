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

    /// Provider for user notification center (local notifications)
    public let notificationCenter: any UserNotificationCenterProtocol

    /// Provider for background photo uploads
    public let backgroundUploadManager: any BackgroundUploadManagerProtocol

    /// Provider for OAuth session presentation (e.g. ASWebAuthenticationSession on iOS)
    public let oauthSessionProvider: any OAuthSessionProvider

    public init(
        appLifecycle: any AppLifecycleProviding,
        deviceInfo: any DeviceInfoProviding,
        pushNotificationRegistrar: any PushNotificationRegistrarProtocol,
        notificationCenter: any UserNotificationCenterProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = UnavailableBackgroundUploadManager(),
        oauthSessionProvider: any OAuthSessionProvider = UnavailableOAuthSessionProvider()
    ) {
        self.appLifecycle = appLifecycle
        self.deviceInfo = deviceInfo
        self.pushNotificationRegistrar = pushNotificationRegistrar
        self.notificationCenter = notificationCenter
        self.backgroundUploadManager = backgroundUploadManager
        self.oauthSessionProvider = oauthSessionProvider
    }
}

// MARK: - Test/Mock Support

/// Mock app lifecycle provider for testing.
///
/// Each instance defaults to a UUID-suffixed notification name so that
/// `SessionStateMachine` instances observing on `NotificationCenter.default`
/// only receive lifecycle events from their own provider. Sharing a fixed
/// name across instances would let one test's background event wedge another
/// test's libxmtp DB pool via `dropLocalDatabaseConnection`.
public final class MockAppLifecycleProvider: AppLifecycleProviding, @unchecked Sendable {
    public let didEnterBackgroundNotification: Notification.Name
    public let willEnterForegroundNotification: Notification.Name
    public let didBecomeActiveNotification: Notification.Name

    private var _currentState: AppState

    @MainActor
    public var currentState: AppState { _currentState }

    public init(
        currentState: AppState = .active,
        didEnterBackgroundNotification: Notification.Name? = nil,
        willEnterForegroundNotification: Notification.Name? = nil,
        didBecomeActiveNotification: Notification.Name? = nil
    ) {
        let suffix = UUID().uuidString
        self._currentState = currentState
        self.didEnterBackgroundNotification = didEnterBackgroundNotification
            ?? Notification.Name("MockDidEnterBackground.\(suffix)")
        self.willEnterForegroundNotification = willEnterForegroundNotification
            ?? Notification.Name("MockWillEnterForeground.\(suffix)")
        self.didBecomeActiveNotification = didBecomeActiveNotification
            ?? Notification.Name("MockDidBecomeActive.\(suffix)")
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
            pushNotificationRegistrar: MockPushNotificationRegistrarProvider(),
            notificationCenter: MockUserNotificationCenter(),
            backgroundUploadManager: MockBackgroundUploadManager()
        )
    }
}
