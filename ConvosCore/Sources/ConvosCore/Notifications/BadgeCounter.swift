import Foundation

public enum BadgeCounter {
    private static let badgeCountKey: String = "convos.badge.count"

    public static func increment(appGroupIdentifier: String) -> Int {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return 1 }
        let current = defaults.integer(forKey: badgeCountKey)
        let next = current + 1
        defaults.set(next, forKey: badgeCountKey)
        return next
    }

    public static func reset(appGroupIdentifier: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(0, forKey: badgeCountKey)
    }
}
