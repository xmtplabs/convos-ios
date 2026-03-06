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
            return UserDefaults.standard.object(forKey: Constant.includeInfoWithInvitesKey) as? Bool ?? false
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
            return UserDefaults.standard.object(forKey: Constant.assistantsEnabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.assistantsEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.assistantsEnabledKey)
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
    }

    private enum Constant {
        static let autoRevealPhotosKey: String = "globalAutoRevealPhotos"
        static let includeInfoWithInvitesKey: String = "globalIncludeInfoWithInvites"
        static let assistantsEnabledKey: String = "globalAssistantsEnabled"
    }
}
