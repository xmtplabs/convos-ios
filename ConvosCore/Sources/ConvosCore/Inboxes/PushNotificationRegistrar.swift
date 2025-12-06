import Foundation
import UIKit
import UserNotifications

/// Manages push notification token storage and authorization requests.
/// All methods are static since push token is app-level, not inbox-specific.
public final class PushNotificationRegistrar {
    private static var _token: String?

    /// Saves the push token in memory and notifies observers of the change.
    /// Called by AppDelegate when APNS token is received.
    /// Note: Token is intentionally not persisted per Apple guidelines -
    /// APNs issues fresh tokens on restore, new device, or OS reinstall.
    public static func save(token: String) {
        guard token != _token else { return }
        _token = token
        NotificationCenter.default.post(name: .convosPushTokenDidChange, object: nil)
    }

    /// Returns the current push token, if available.
    public static var token: String? {
        _token
    }

    /// Requests notification authorization if not already granted, then registers for remote notifications.
    /// Can be called from anywhere in the app when user takes an action that would benefit from notifications.
    public static func requestNotificationAuthorizationIfNeeded() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        if settings.authorizationStatus == .authorized {
            // Already authorized, just ensure we're registered for remote notifications
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return true
        }

        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                // Authorization granted, register for remote notifications to get APNS token
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                Log.info("Notification authorization granted, registering for remote notifications")
            } else {
                Log.info("Notification authorization denied by user")
            }
            return granted
        } catch {
            Log.warning("Notification authorization failed: \(error)")
            return false
        }
    }
}
