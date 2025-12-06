import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
#endif

private func registerForRemoteNotifications() {
#if os(macOS)
	NSApplication.shared.registerForRemoteNotifications()
#elseif os(iOS) || os(tvOS) || os(watchOS)
	UIApplication.shared.registerForRemoteNotifications()
#endif
}

/// Manages push notification token storage and authorization requests.
/// All methods are static since push token is app-level, not inbox-specific.
public final class PushNotificationRegistrar {
    private static var tokenKey: String = "pushToken"

    /// Saves the push token to UserDefaults and notifies observers of the change.
    /// Called by AppDelegate when APNS token is received.
    public static func save(token: String) {
        let existingToken = UserDefaults.standard.string(forKey: tokenKey)
        guard token != existingToken else { return }

        UserDefaults.standard.set(token, forKey: tokenKey)
        NotificationCenter.default.post(name: .convosPushTokenDidChange, object: nil)
    }

    /// Returns the current push token from UserDefaults, if available.
    public static var token: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    /// Requests notification authorization if not already granted, then registers for remote notifications.
    /// Can be called from anywhere in the app when user takes an action that would benefit from notifications.
    public static func requestNotificationAuthorizationIfNeeded() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        if settings.authorizationStatus == .authorized {
            // Already authorized, just ensure we're registered for remote notifications
            await MainActor.run {
				registerForRemoteNotifications()
            }
            return true
        }

        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                // Authorization granted, register for remote notifications to get APNS token
                await MainActor.run {
                    registerForRemoteNotifications()
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
