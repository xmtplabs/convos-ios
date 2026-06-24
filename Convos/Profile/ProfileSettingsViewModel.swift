import Combine
import ConvosCore
import SwiftUI

enum ProfileSettingsError: Error {
    case notBound
}

/// Whether the global profile has been definitively loaded from the active
/// inbox. Distinct from the profile being empty: `.loading` means the answer
/// is not known yet (cold launch before inbox ready, pairing transition), so
/// consumers like the onboarding coordinator must not treat the current
/// (default) values as "the user has no profile".
enum ProfileLoadState: Equatable {
    case loading
    case loaded
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

    /// `.loading` until the bound repository delivers its first definitive
    /// answer. The setter is internal so tests can preset the state; production
    /// code must only write it from `bindInternal`/`rebind`.
    var loadState: ProfileLoadState = .loading {
        didSet { loadStateSubject.send(loadState) }
    }
    @ObservationIgnored
    private let loadStateSubject: CurrentValueSubject<ProfileLoadState, Never> = .init(.loading)

    private var session: (any SessionManagerProtocol)?
    private var writer: (any MyGlobalProfileWriterProtocol)?
    private var repository: (any MyGlobalProfileRepositoryProtocol)?
    private var cancellables: Set<AnyCancellable> = []
    /// The last name loaded from (or saved to) the global profile. Used to
    /// reject an empty save: once a name is set it cannot be cleared.
    private var loadedDisplayName: String?
    /// The last metadata loaded from the global profile. The My Info editor does
    /// not edit metadata, so we carry this through on save instead of writing
    /// nil - otherwise a name-only edit would clear stored metadata (e.g. the
    /// profile emoji). Kept fresh by `apply(profile:)`.
    private var loadedMetadata: ProfileMetadata?

    private init() {}

    /// Suspends until the profile load state is known, returning true, or
    /// until `timeout` elapses, returning false. Returns immediately when the
    /// profile is already loaded.
    func waitForProfileLoad(timeout: TimeInterval) async -> Bool {
        if loadState == .loaded { return true }
        let timeoutPublisher = Just(ProfileLoadState.loading)
            .delay(for: .seconds(timeout), scheduler: DispatchQueue.main)
        let firstResolution = loadStateSubject
            .filter { $0 == .loaded }
            .merge(with: timeoutPublisher)
            .first()
        for await state in firstResolution.values {
            return state == .loaded
        }
        return loadState == .loaded
    }

    func bind(session: any SessionManagerProtocol) {
        guard self.session == nil else { return }
        bindInternal(session: session)
    }

    /// Re-binds the singleton to a freshly-built `MessagingService` after a
    /// session-level reset (e.g. the joiner just adopted a paired
    /// identity and `SessionManager.refreshAfterPairingCompleted()`
    /// dropped the placeholder service + wiped its GRDB rows). Without
    /// this the existing `writer` / `repository` still reference the
    /// placeholder inbox id, so the post-pair seed never reaches the
    /// `profileSettings` getters that gate the in-conversation
    /// onboarding prompt.
    func rebind(session: any SessionManagerProtocol) {
        cancellables.removeAll()
        self.session = nil
        writer = nil
        repository = nil
        clearEditingFields()
        loadState = .loading
        bindInternal(session: session)
    }

    private func bindInternal(session: any SessionManagerProtocol) {
        self.session = session
        let messagingService = session.messagingServiceSync()
        self.writer = messagingService.myGlobalProfileWriter()
        let repository = messagingService.myGlobalProfileRepository()
        self.repository = repository
        // Synchronous fast path: succeeds when the inbox is already ready and
        // a profile row exists (warm starts), so dependents don't have to wait
        // for the async observation's first emission.
        if let profile = try? repository.fetch() {
            apply(profile: profile)
            loadState = .loaded
        }
        // `.pending` deliberately doesn't downgrade `loadState`: it is the
        // subject's replayed initial value and would otherwise undo the fast
        // path above. Transitions back to loading happen only via `rebind`.
        repository.myGlobalProfileLoadStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard case .loaded(let profile) = state else { return }
                self?.apply(profile: profile)
                self?.loadState = .loaded
            }
            .store(in: &cancellables)
    }

    private func apply(profile: MyProfile?) {
        editingDisplayName = profile?.name ?? ""
        loadedDisplayName = profile?.name
        loadedMetadata = profile?.metadata
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
        // A name, once set, cannot be cleared: an empty field falls back to the
        // stored name rather than writing nil, and the field is restored so the
        // UI reflects that the empty value was rejected. First-time users with
        // no stored name are unaffected (there is nothing to preserve).
        let resolvedName: String?
        if trimmedName.isEmpty, let loadedDisplayName {
            resolvedName = loadedDisplayName
            editingDisplayName = loadedDisplayName
        } else {
            resolvedName = trimmedName.isEmpty ? nil : trimmedName
        }
        let imageData = profileImage?.jpegData(compressionQuality: 1.0)
        let assetIdentifier = imageData == nil ? nil : profileImageAssetIdentifier
        try await writer.save(
            name: resolvedName,
            imageData: imageData,
            imageAssetIdentifier: assetIdentifier,
            metadata: loadedMetadata
        )
        // Arm the empty-save guard immediately. `loadedDisplayName` is otherwise
        // only refreshed by the async profile observation, so a first-time user
        // who saves a name and then clears + saves again before that fires would
        // skip the guard above. (The writer also preserves the stored name on an
        // empty save, so this is defense-in-depth + keeps the field restore working.)
        if let resolvedName {
            loadedDisplayName = resolvedName
        }
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
        clearEditingFields()
        guard let writer else { return }
        Task {
            do {
                try await writer.delete()
            } catch {
                Log.error("Failed deleting profile settings: \(error.localizedDescription)")
            }
        }
    }

    private func clearEditingFields() {
        editingDisplayName = ""
        loadedDisplayName = nil
        loadedMetadata = nil
        profileImage = nil
        profileImageAssetIdentifier = nil
        profileImageContentDigest = nil
    }
}
