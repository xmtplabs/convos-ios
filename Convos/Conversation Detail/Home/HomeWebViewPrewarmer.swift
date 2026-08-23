import ConvosCore
import UIKit
import WebKit

/// Warms the home's web view at launch so the first conversation opened does
/// not pay to build one. The view itself is kept by `HomeWebViewPool`, which is
/// what hands it to the surface - warming a view nobody adopts buys nothing.
///
/// Only runs after the session reaches inbox-ready, so the warm-up stays off
/// the contention-heavy launch path (mirrors
/// `ConvosApp.startMetricsIdentification`). Everything that can run off the
/// main thread does; only the UIKit/WebKit touches hop to the main actor.
enum HomeWebViewPrewarmer {
    static func prewarmIfNeeded(session: any SessionManagerProtocol) {
        Task.detached(priority: .utility) {
            do {
                _ = try await session.messagingService().sessionStateManager.waitForInboxReadyResult()
            } catch {
                // Warm-up is best-effort; a failed session bind just skips it.
                return
            }
            await MainActor.run { HomeWebViewPool.shared.warm() }
        }
    }
}
