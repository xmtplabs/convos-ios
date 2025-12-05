import ConvosCore
import Foundation
import UIKit

struct QuicknameSettings: Equatable {
    struct RandomizerSettings: Codable, Equatable {
        let tags: [String]

        var summary: String {
            tags.joined(separator: " • ")
        }
    }

    // Internal Codable struct for UserDefaults
    private struct StoredSettings: Codable {
        let displayName: String
        let randomizerSettings: RandomizerSettings
    }
    private static var userDefaultsKey: String = "QuicknameSettings"

    let displayName: String
    let profileImage: UIImage?
    let randomizerSettings: RandomizerSettings

    var isDefault: Bool {
        self == Self.defaultSettings
    }

    var randomizerSummary: String {
        randomizerSettings.summary
    }

    var profile: Profile {
        .init(
            inboxId: "",
            name: displayName.isEmpty ? nil : displayName,
            avatar: profileImage == nil ? nil : Self.defaultProfileImageURL?.absoluteString
        )
    }

    private static var defaultProfileImageURL: URL? {
        guard let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return documentsDirectory
            .appendingPathComponent("default-profile-image.jpg")
    }

    func with(displayName: String) -> Self {
        .init(
            displayName: displayName,
            profileImage: profileImage,
            randomizerSettings: randomizerSettings
        )
    }

    func with(profileImage: UIImage?) -> Self {
        .init(
            displayName: displayName,
            profileImage: profileImage,
            randomizerSettings: randomizerSettings
        )
    }

    func with(randomizerSettings: RandomizerSettings) -> Self {
        .init(
            displayName: displayName,
            profileImage: profileImage,
            randomizerSettings: randomizerSettings
        )
    }

    func profile(inboxId: String = "") -> Profile {
        .init(
            inboxId: inboxId,
            name: displayName.isEmpty ? nil : displayName,
            avatar: profileImage == nil ? nil : Self.defaultProfileImageURL?.absoluteString
        )
    }

    func save() throws {
        guard !isDefault else {
            delete()
            return
        }

        // Save settings (except image) to UserDefaults
        let storedSettings = StoredSettings(
            displayName: displayName,
            randomizerSettings: randomizerSettings
        )
        let data = try JSONEncoder().encode(storedSettings)
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)

        // Save profile image to disk
        if let profileImage = profileImage,
           let imageURL = Self.defaultProfileImageURL,
           let jpegData = profileImage.jpegData(compressionQuality: 1.0) {
            try jpegData.write(to: imageURL)
        } else if let imageURL = Self.defaultProfileImageURL {
            // Remove image if nil
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    func delete() {
        // Remove from UserDefaults
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)

        // Delete profile image from disk
        if let imageURL = Self.defaultProfileImageURL {
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    private static var defaultSettings: Self {
        QuicknameSettings(
            displayName: "",
            profileImage: nil,
            randomizerSettings: RandomizerSettings(tags: [
                "gender neutral",
                "nature",
                "weird"
            ]),
        )
    }

    static func current() -> QuicknameSettings {
        // Load settings from UserDefaults
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let storedSettings = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            // Return default if nothing saved
            return .defaultSettings
        }

        // Load profile image from disk if it exists
        var profileImage: UIImage?
        if let imageURL = defaultProfileImageURL,
           FileManager.default.fileExists(atPath: imageURL.path),
           let imageData = try? Data(contentsOf: imageURL) {
            profileImage = UIImage(data: imageData)
        }

        return QuicknameSettings(
            displayName: storedSettings.displayName,
            profileImage: profileImage,
            randomizerSettings: storedSettings.randomizerSettings,
        )
    }
}
