import Foundation

final class GlobalConvoDefaults {
    static let shared: GlobalConvoDefaults = .init()

    var revealModeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Constant.revealModeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Constant.revealModeKey) }
    }

    var includeInfoWithInvites: Bool {
        get { UserDefaults.standard.object(forKey: Constant.includeInfoWithInvitesKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Constant.includeInfoWithInvitesKey) }
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: Constant.revealModeKey)
        UserDefaults.standard.removeObject(forKey: Constant.includeInfoWithInvitesKey)
    }

    private enum Constant {
        static let revealModeKey: String = "globalRevealMode"
        static let includeInfoWithInvitesKey: String = "globalIncludeInfoWithInvites"
    }
}
