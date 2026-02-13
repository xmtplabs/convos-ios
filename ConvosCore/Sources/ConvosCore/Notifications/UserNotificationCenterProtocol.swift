@preconcurrency import UserNotifications

public protocol UserNotificationCenterProtocol: Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: @preconcurrency UserNotificationCenterProtocol {}
