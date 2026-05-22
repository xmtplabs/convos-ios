import Foundation
import Observation

@Observable
final class GlobalConvoDefaults: @unchecked Sendable {
    static let shared: GlobalConvoDefaults = .init()

    var autoRevealPhotos: Bool {
        get {
            access(keyPath: \.autoRevealPhotos)
            // Default true means photos are auto-revealed (Reveal Mode toggle is off).
            return UserDefaults.standard.object(forKey: Constant.autoRevealPhotosKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.autoRevealPhotos) {
                UserDefaults.standard.set(newValue, forKey: Constant.autoRevealPhotosKey)
            }
        }
    }

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

    var agentsEnabled: Bool {
        get {
            access(keyPath: \.agentsEnabled)
            return UserDefaults.standard.object(forKey: Constant.agentsEnabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.agentsEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.agentsEnabledKey)
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
        withMutation(keyPath: \.autoRevealPhotos) {
            UserDefaults.standard.removeObject(forKey: Constant.autoRevealPhotosKey)
        }
        withMutation(keyPath: \.includeInfoWithInvites) {
            UserDefaults.standard.removeObject(forKey: Constant.includeInfoWithInvitesKey)
        }
        withMutation(keyPath: \.agentsEnabled) {
            UserDefaults.standard.removeObject(forKey: Constant.agentsEnabledKey)
        }
        withMutation(keyPath: \.sendReadReceipts) {
            UserDefaults.standard.removeObject(forKey: Constant.sendReadReceiptsKey)
        }
    }

    private enum Constant {
        static let autoRevealPhotosKey: String = "globalAutoRevealPhotos"
        static let includeInfoWithInvitesKey: String = "globalIncludeInfoWithInvites"
        static let agentsEnabledKey: String = "globalAssistantsEnabled"
        static let sendReadReceiptsKey: String = "globalSendReadReceipts"
    }
}
