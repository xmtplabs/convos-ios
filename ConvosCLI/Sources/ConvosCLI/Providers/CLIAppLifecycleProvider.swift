import ConvosCore
import Foundation

/// CLI app lifecycle provider - CLI apps are always "active" when running
public final class CLIAppLifecycleProvider: AppLifecycleProviding, Sendable {
    public let didEnterBackgroundNotification: Notification.Name
    public let willEnterForegroundNotification: Notification.Name
    public let didBecomeActiveNotification: Notification.Name

    @MainActor
    public var currentState: AppState { .active }

    public init() {
        // CLI doesn't have background/foreground transitions, but we need valid notification names
        self.didEnterBackgroundNotification = Notification.Name("CLIDidEnterBackground")
        self.willEnterForegroundNotification = Notification.Name("CLIWillEnterForeground")
        self.didBecomeActiveNotification = Notification.Name("CLIDidBecomeActive")
    }
}
