import Foundation
import Observation

@Observable
final class GlobalConvoDefaults: @unchecked Sendable {
    static let shared: GlobalConvoDefaults = .init()

    var autoRevealPhotos: Bool {
        get {
            access(keyPath: \.autoRevealPhotos)
            // Default false means photos are not auto-revealed (blur incoming pics is on).
            return UserDefaults.standard.object(forKey: Constant.autoRevealPhotosKey) as? Bool ?? false
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

    var assistantsEnabled: Bool {
        get {
            access(keyPath: \.assistantsEnabled)
            guard assistantCodeUnlocked else { return false }
            return UserDefaults.standard.object(forKey: Constant.assistantsEnabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.assistantsEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.assistantsEnabledKey)
            }
        }
    }

    var assistantCodeUnlocked: Bool {
        get {
            access(keyPath: \.assistantCodeUnlocked)
            return UserDefaults.standard.bool(forKey: Constant.assistantCodeUnlockedKey)
        }
        set {
            withMutation(keyPath: \.assistantCodeUnlocked) {
                UserDefaults.standard.set(newValue, forKey: Constant.assistantCodeUnlockedKey)
            }
        }
    }

    var assistantInviteCode: String? {
        get {
            access(keyPath: \.assistantInviteCode)
            return UserDefaults.standard.string(forKey: Constant.assistantInviteCodeKey)
        }
        set {
            withMutation(keyPath: \.assistantInviteCode) {
                UserDefaults.standard.set(newValue, forKey: Constant.assistantInviteCodeKey)
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
        withMutation(keyPath: \.assistantsEnabled) {
            UserDefaults.standard.removeObject(forKey: Constant.assistantsEnabledKey)
        }
        withMutation(keyPath: \.assistantCodeUnlocked) {
            UserDefaults.standard.removeObject(forKey: Constant.assistantCodeUnlockedKey)
        }
        withMutation(keyPath: \.assistantInviteCode) {
            UserDefaults.standard.removeObject(forKey: Constant.assistantInviteCodeKey)
        }
        withMutation(keyPath: \.sendReadReceipts) {
            UserDefaults.standard.removeObject(forKey: Constant.sendReadReceiptsKey)
        }
    }

    private enum Constant {
        static let autoRevealPhotosKey: String = "globalAutoRevealPhotos"
        static let includeInfoWithInvitesKey: String = "globalIncludeInfoWithInvites"
        static let assistantsEnabledKey: String = "globalAssistantsEnabled"
        static let assistantCodeUnlockedKey: String = "globalAssistantCodeUnlocked"
        static let assistantInviteCodeKey: String = "globalAssistantInviteCode"
        static let sendReadReceiptsKey: String = "globalSendReadReceipts"
    }
}
