import Combine
import ConvosCore
import SwiftUI

@MainActor
@Observable
class ProfileSettingsViewModel {
    static let shared: ProfileSettingsViewModel = .init()

    var profileSettings: ProfileSettings {
        .init(displayName: editingDisplayName, profileImage: profileImage)
    }
    var profile: Profile {
        profileSettings.profile
    }
    var editingDisplayName: String = ""
    var profileImage: UIImage?
    /// `PHAsset.localIdentifier` for the asset backing `profileImage` when picked from the
    /// photo library. Persisted alongside the image so we can preselect it next time the
    /// picker opens and detect when the user picks a different asset.
    var profileImageAssetIdentifier: String?

    var exampleDisplayName: String = "Somebody"

    private var session: (any SessionManagerProtocol)?
    private var writer: (any MyGlobalProfileWriterProtocol)?
    private var repository: (any MyGlobalProfileRepositoryProtocol)?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    func bind(session: any SessionManagerProtocol) {
        guard self.session == nil else { return }
        self.session = session
        let messagingService = session.messagingServiceSync()
        self.writer = messagingService.myGlobalProfileWriter()
        let repository = messagingService.myGlobalProfileRepository()
        self.repository = repository
        if let profile = try? repository.fetch() {
            apply(profile: profile)
        }
        repository.myGlobalProfilePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] profile in
                self?.apply(profile: profile)
            }
            .store(in: &cancellables)
    }

    private func apply(profile: MyProfile?) {
        editingDisplayName = profile?.name ?? ""
        profileImage = profile?.imageData.flatMap(UIImage.init(data:))
        profileImageAssetIdentifier = profile?.imageAssetIdentifier
    }

    func save() {
        guard let writer else {
            Log.error("ProfileSettingsViewModel.save called before bind")
            return
        }
        let trimmedName = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String? = trimmedName.isEmpty ? nil : trimmedName
        let imageData = profileImage?.jpegData(compressionQuality: 1.0)
        let assetIdentifier = imageData == nil ? nil : profileImageAssetIdentifier
        let isDefault = profileSettings.isDefault
        Task {
            do {
                try await writer.save(
                    name: resolvedName,
                    imageData: imageData,
                    imageAssetIdentifier: assetIdentifier,
                    metadata: nil
                )
                if !isDefault {
                    ConversationOnboardingCoordinator.markQuicknameEditorShown()
                }
            } catch {
                Log.error("Failed saving profile settings: \(error.localizedDescription)")
            }
        }
    }

    func delete() {
        editingDisplayName = ""
        profileImage = nil
        profileImageAssetIdentifier = nil
        guard let writer else { return }
        Task {
            do {
                try await writer.delete()
            } catch {
                Log.error("Failed deleting profile settings: \(error.localizedDescription)")
            }
        }
    }
}
