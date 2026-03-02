import Foundation
import Observation

@Observable
final class GlobalConvoDefaults: @unchecked Sendable {
    static let shared: GlobalConvoDefaults = .init()

    var revealModeEnabled: Bool {
        get {
            access(keyPath: \.revealModeEnabled)
            return UserDefaults.standard.object(forKey: Constant.revealModeKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.revealModeEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.revealModeKey)
            }
        }
    }

    var includeInfoWithInvites: Bool {
        get {
            access(keyPath: \.includeInfoWithInvites)
            return UserDefaults.standard.object(forKey: Constant.includeInfoWithInvitesKey) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.includeInfoWithInvites) {
                UserDefaults.standard.set(newValue, forKey: Constant.includeInfoWithInvitesKey)
            }
        }
    }

    func reset() {
        withMutation(keyPath: \.revealModeEnabled) {
            UserDefaults.standard.removeObject(forKey: Constant.revealModeKey)
        }
        withMutation(keyPath: \.includeInfoWithInvites) {
            UserDefaults.standard.removeObject(forKey: Constant.includeInfoWithInvitesKey)
        }
    }

    private enum Constant {
        static let revealModeKey: String = "globalRevealMode"
        static let includeInfoWithInvitesKey: String = "globalIncludeInfoWithInvites"
    }
}
