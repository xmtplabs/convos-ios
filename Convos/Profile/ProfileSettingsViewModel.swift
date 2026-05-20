import Combine
import ConvosCore
import SwiftUI

enum ProfileSettingsError: Error {
    case notBound
}

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
        markProfileEditorShownIfPopulated()
        Task { try? await saveAndAwait() }
    }

    /// Awaitable variant for callers that need to advance UI state only after persistence
    /// succeeds (e.g. the onboarding coordinator, which gates `hasSetProfile` and the
    /// `.savedProfileSuccess` transition on a confirmed write).
    func saveAndAwait() async throws {
        guard let writer else {
            Log.error("ProfileSettingsViewModel.saveAndAwait called before bind")
            throw ProfileSettingsError.notBound
        }
        let trimmedName = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String? = trimmedName.isEmpty ? nil : trimmedName
        let imageData = profileImage?.jpegData(compressionQuality: 1.0)
        let assetIdentifier = imageData == nil ? nil : profileImageAssetIdentifier
        try await writer.save(
            name: resolvedName,
            imageData: imageData,
            imageAssetIdentifier: assetIdentifier,
            metadata: nil
        )
        markProfileEditorShownIfPopulated()
    }

    /// Record that the user has actually set a non-default profile.
    /// `ConversationOnboardingCoordinator.startProfileSetupFlow` reads this flag to decide
    /// whether to prompt for "Add your name and pic" on the first chat; without it set, a
    /// user who configures their profile up front in Settings still gets the onboarding
    /// prompt and sees "Chat as Somebody" in the input bar.
    ///
    /// Called synchronously from `save()` so the flag lands before the user can navigate
    /// to a new conversation. If we only set it inside `saveAndAwait()`, the async write
    /// races against the join flow: the user dismisses My info, immediately joins a group,
    /// and `hasShownProfileEditor` is still false when the onboarding coordinator checks.
    private func markProfileEditorShownIfPopulated() {
        let trimmedName = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let didSetSomething = !trimmedName.isEmpty || profileImage != nil
        if didSetSomething {
            ConversationOnboardingCoordinator.markProfileEditorShown()
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
