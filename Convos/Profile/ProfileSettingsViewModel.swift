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
    /// photo library. Used purely so the picker can preselect the previously chosen asset
    /// next time it opens — change detection uses `profileImageContentDigest` instead.
    var profileImageAssetIdentifier: String?
    /// Content-addressed digest of the persisted `profileImage`. Set by activate-sync's
    /// uploader and by `apply(profile:)`; consumers can compare it against
    /// `Profile.imageSourceContentDigest` to confirm a per-conversation avatar was synced
    /// from the current global photo (used to avoid avatar flicker mid-sync).
    var profileImageContentDigest: String?

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
        profileImageContentDigest = profile?.imageContentDigest
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
                    ConversationOnboardingCoordinator.markProfileEditorShown()
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
        profileImageContentDigest = nil
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
