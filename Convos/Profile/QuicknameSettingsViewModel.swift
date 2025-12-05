import Combine
import ConvosCore
import SwiftUI

@Observable
class QuicknameSettingsViewModel {
    static let shared: QuicknameSettingsViewModel = .init()

    var quicknameSettings: QuicknameSettings {
        .init(
            displayName: editingDisplayName,
            profileImage: profileImage,
            randomizerSettings: .init(tags: tags)
        )
    }
    var profile: Profile {
        quicknameSettings.profile
    }
    var editingDisplayName: String = ""
    var profileImage: UIImage?
    var tags: [String] = []

    var exampleDisplayName: String = "Somebody"

    private init() {
        let currentSettings = QuicknameSettings.current()
        editingDisplayName = currentSettings.displayName
        profileImage = currentSettings.profileImage
        tags = currentSettings.randomizerSettings.tags
    }

    func save() {
        do {
            try quicknameSettings.save()
        } catch {
            Log.error("Failed saving quickname settings: \(error.localizedDescription)")
        }
    }

    func delete() {
        editingDisplayName = ""
        profileImage = nil
        quicknameSettings.delete()
    }
}
