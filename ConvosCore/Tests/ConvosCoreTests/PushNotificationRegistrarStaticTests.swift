@testable import ConvosCore
import Foundation
import Testing

/// Stack 1 / D10 regression: `PushNotificationRegistrar.save(token:)` is the
/// hot path AppDelegate calls when APNS delivers the device token. The
/// previous implementation routed through `shared`, which fatalError'd when
/// `configure()` had not been called — fine under the normal SwiftUI cold
/// launch (PlatformProviders.iOS configures before UIKit fires
/// didFinishLaunching) but a crash for the `.iOSExtension` path, UI tests
/// that exercise AppDelegate directly, and any future lifecycle change.
///
/// The graceful no-op trades a crash for a logged drop: missing pushes are
/// recoverable (no DeviceRegistration row in backend), a SIGABRT on a hot
/// callback isn't.
///
/// Serialized so the brief unconfigured window doesn't race with other
/// suites that touch the singleton.
@Suite("PushNotificationRegistrar static convenience", .serialized)
struct PushNotificationRegistrarStaticTests {
    @Test("save(token:) does not crash before configure() — graceful no-op")
    func saveBeforeConfigureDoesNotCrash() {
        PushNotificationRegistrar.resetForTesting()

        // No configure() call here on purpose. The old implementation would
        // fatalError on the next line; the new graceful path logs an error
        // and returns without touching anything.
        PushNotificationRegistrar.save(token: "would-have-crashed-before-fix")
        #expect(PushNotificationRegistrar.token == nil)

        // Reconfigure with the mock so any test in this suite that follows
        // (or runs concurrently against the shared singleton) sees a known
        // configured state instead of the empty post-reset state.
        PushNotificationRegistrar.configure(MockPushNotificationRegistrarProvider())
    }

    @Test("save(token:) forwards to the configured registrar after configure()")
    func saveAfterConfigureForwards() {
        PushNotificationRegistrar.resetForTesting()
        let registrar = MockPushNotificationRegistrarProvider()
        PushNotificationRegistrar.configure(registrar)

        PushNotificationRegistrar.save(token: "real-token")
        #expect(PushNotificationRegistrar.token == "real-token")
    }
}
