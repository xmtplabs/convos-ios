import Foundation
import Observation

@Observable
final class GlobalConvoDefaults: @unchecked Sendable {
    static let shared: GlobalConvoDefaults = .init()

    var includeInfoWithInvites: Bool {
        get {
            access(keyPath: \.includeInfoWithInvites)
            return UserDefaults.standard.object(forKey: Constant.includeInfoWithInvitesKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.includeInfoWithInvites) {
                UserDefaults.standard.set(newValue, forKey: Constant.includeInfoWithInvitesKey)
            }
        }
    }

    var sendReadReceipts: Bool {
        get {
            access(keyPath: \.sendReadReceipts)
            return UserDefaults.standard.object(forKey: Constant.sendReadReceiptsKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.sendReadReceipts) {
                UserDefaults.standard.set(newValue, forKey: Constant.sendReadReceiptsKey)
            }
        }
    }

    func reset() {
        // Clear the orphaned reveal-mode default left by older installs.
        UserDefaults.standard.removeObject(forKey: Constant.legacyAutoRevealPhotosKey)
        withMutation(keyPath: \.includeInfoWithInvites) {
            UserDefaults.standard.removeObject(forKey: Constant.includeInfoWithInvitesKey)
        }
        withMutation(keyPath: \.sendReadReceipts) {
            UserDefaults.standard.removeObject(forKey: Constant.sendReadReceiptsKey)
        }
    }

    private enum Constant {
        static let legacyAutoRevealPhotosKey: String = "globalAutoRevealPhotos"
        static let includeInfoWithInvitesKey: String = "globalIncludeInfoWithInvites"
        static let sendReadReceiptsKey: String = "globalSendReadReceipts"
    }
}
