import Combine
import ConvosComposer
import ConvosCore
import SwiftUI

@MainActor
@Observable
class MyProfileViewModel {
    private let messagingService: any MessagingServiceProtocol
    private let myProfileRepository: any MyProfileRepositoryProtocol
    private(set) var profile: Profile
    private var cancellables: Set<AnyCancellable> = []
    private var updateDisplayNameTask: Task<Void, Never>?
    private var updateImageTask: Task<Void, Never>?
    private var updateMetadataTask: Task<Void, Never>?
    private var pendingUpdateCount: Int = 0

    var isEditingDisplayName: Bool = false
    var editingDisplayName: String = ""
    var saveDisplayNameAsProfile: Bool = false

    var profileImage: UIImage?
    var editingEmoji: String = ""

    // Computed properties for display
    var displayName: String {
        isEditingDisplayName ? editingDisplayName : profile.name ?? ""
    }

    init(
        inboxId: String,
        messagingService: any MessagingServiceProtocol,
        myProfileRepository: any MyProfileRepositoryProtocol
    ) {
        self.profile = .empty(inboxId: inboxId)
        self.messagingService = messagingService
        self.myProfileRepository = myProfileRepository

        do {
            self.profile = try myProfileRepository.fetch()
        } catch {
            Log.error("Failed loading profile")
        }

        setupMyProfileRepository()

        self.editingDisplayName = profile.name ?? ""
        self.editingEmoji = profile.profileEmoji ?? ""
        self.profileImage = Self.preferredImage(for: profile)
    }

    func cancelEditingDisplayName() {
        isEditingDisplayName = false
        editingDisplayName = profile.name ?? ""
    }

    // MARK: Private

    private func setupMyProfileRepository() {
        myProfileRepository.myProfilePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] profile in
                guard let self else { return }
                self.profileImage = Self.preferredImage(for: profile)
                self.profile = profile
                self.editingEmoji = profile.profileEmoji ?? ""
            }
            .store(in: &cancellables)
    }

    /// Returns the image to display for the current user in this conversation.
    ///
    /// Per-conversation profiles can hold either a *synced* avatar (uploaded from the
    /// user's global photo, so `imageSourceContentDigest` is set) or a *per-conversation
    /// override* (the user picked a different photo just for this conversation, so
    /// `imageSourceContentDigest` is nil).
    ///
    /// - No per-conversation avatar → fall through to the global (if any).
    /// - Per-conversation override (digest nil) → keep the per-conversation cache; the
    ///   user explicitly chose a different photo here.
    /// - Synced per-conversation avatar (digest set) → prefer the in-memory global
    ///   image. If the digests already match, this just avoids an async cache fetch.
    ///   If they differ, the global is newer (the user just changed it) and
    ///   activate-sync will catch the per-conversation avatar up shortly — showing the
    ///   new global immediately avoids flickering through the stale cached photo.
    private static func preferredImage(for profile: Profile) -> UIImage? {
        let global = ProfileSettingsViewModel.shared
        if profile.avatar == nil {
            return global.profileImage
        }
        if profile.imageSourceContentDigest == nil {
            return ImageCache.shared.image(for: profile)
        }
        if global.profileImage != nil {
            return global.profileImage
        }
        return ImageCache.shared.image(for: profile)
    }

    private func beginUpdate() {
        if pendingUpdateCount == 0 {
            myProfileRepository.suspendObservation()
        }
        pendingUpdateCount += 1
    }

    private func endUpdate() {
        pendingUpdateCount -= 1
        if pendingUpdateCount == 0 {
            myProfileRepository.resumeObservation()
        }
    }

    private func update(displayName: String, conversationId: String) {
        editingDisplayName = displayName
        updateDisplayNameTask?.cancel()
        beginUpdate()
        let repository = messagingService.profilesRepository()
        updateDisplayNameTask = Task { [weak self] in
            guard self != nil else { return }
            defer { Task { @MainActor [weak self] in self?.endUpdate() } }
            do {
                try await repository.publishMyProfile(
                    displayName: displayName,
                    avatarBytes: nil,
                    priorityConversationId: conversationId
                )
            } catch {
                Log.error("Error updating profile display name: \(error.localizedDescription)")
            }
        }
    }

    private func update(profileMetadata: ProfileMetadata?, conversationId: String) {
        updateMetadataTask?.cancel()
        beginUpdate()
        let displayNameTask = updateDisplayNameTask
        let repository = messagingService.profilesRepository()
        updateMetadataTask = Task { [weak self] in
            guard self != nil else { return }
            defer { Task { @MainActor [weak self] in self?.endUpdate() } }
            await displayNameTask?.value
            do {
                try await repository.publishMyProfileMetadata(profileMetadata)
            } catch {
                Log.error("Error updating profile metadata: \(error.localizedDescription)")
            }
        }
    }

    private func update(profileImage: UIImage, conversationId: String) {
        self.profileImage = profileImage
        ImageCache.shared.cacheImage(profileImage, for: profile.imageCacheIdentifier, imageFormat: .jpg)

        updateImageTask?.cancel()
        beginUpdate()
        let displayNameTask = updateDisplayNameTask
        let repository = messagingService.profilesRepository()
        // Compress for upload: every conversation re-encrypts and re-uploads
        // whatever we pass, so a raw multi-MB encode multiplies across the
        // whole conversation list. Falls back to the uncompressed encode only
        // if compression fails.
        let avatarBytes = ImageCache.shared.prepareForUpload(profileImage, forIdentifier: profile.imageCacheIdentifier)
            ?? profileImage.jpegData(compressionQuality: 1.0)
        updateImageTask = Task { [weak self] in
            guard self != nil else { return }
            defer { Task { @MainActor [weak self] in self?.endUpdate() } }
            // Wait for any pending display name update to complete first,
            // so the avatar update reads the profile with the correct name
            await displayNameTask?.value
            do {
                try await repository.publishMyProfile(
                    displayName: nil,
                    avatarBytes: avatarBytes,
                    priorityConversationId: conversationId
                )
            } catch {
                Log.error("Error updating profile image: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Public

    func update(using profile: Profile, profileImage: UIImage?, conversationId: String) {
        self.editingDisplayName = profile.name ?? ""
        self.editingEmoji = profile.profileEmoji ?? ""
        self.profileImage = profileImage
        self.profile = profile.with(inboxId: self.profile.inboxId)
        // update image first so we don't see the 'monogram' flash in avatar
        if let name = profile.name {
            update(displayName: name, conversationId: conversationId)
        }
        if let profileImage = profileImage {
            update(profileImage: profileImage, conversationId: conversationId)
        }
    }

    func onEndedEditing(for conversationId: String) -> Bool {
        var didChange = false

        let trimmedDisplayName = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = editingEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let latestProfile = try? myProfileRepository.fetch()
        // Don't push an empty name over an existing one (it would render as
        // "Somebody"). The writer guards this too, but skipping here avoids a
        // redundant re-broadcast of the unchanged name.
        let wouldClearExistingName = trimmedDisplayName.isEmpty && (latestProfile?.name?.isEmpty == false)
        // The name we actually use everywhere below: never blank out an existing
        // name. When a clear is prevented this is the preserved stored name, so
        // neither the field nor the "save as profile" forward gets the stale
        // empty string.
        let resolvedDisplayName = wouldClearExistingName ? (latestProfile?.name ?? "") : trimmedDisplayName
        if !wouldClearExistingName, latestProfile == nil || latestProfile?.name != trimmedDisplayName {
            update(displayName: trimmedDisplayName, conversationId: conversationId)
            didChange = true
        } else if wouldClearExistingName {
            // Clearing was prevented; restore the field so it doesn't show blank
            // while the stored name is actually preserved (mirrors saveAndAwait).
            editingDisplayName = resolvedDisplayName
        }

        let updatedMetadata: ProfileMetadata? = {
            var metadata = latestProfile?.metadata ?? [:]
            if trimmedEmoji.isEmpty {
                metadata.removeValue(forKey: Constant.emojiMetadataKey)
            } else {
                metadata[Constant.emojiMetadataKey] = .string(trimmedEmoji)
            }
            return metadata.isEmpty ? nil : metadata
        }()
        if latestProfile?.profileEmoji != (trimmedEmoji.isEmpty ? nil : trimmedEmoji) {
            update(profileMetadata: updatedMetadata, conversationId: conversationId)
            didChange = true
        }

        let pendingProfileImage = profileImage
        if let pendingProfileImage {
            update(profileImage: pendingProfileImage, conversationId: conversationId)
            didChange = true
            self.profileImage = nil
        }

        if saveDisplayNameAsProfile {
            // QuickEditView writes the asset identifier directly to
            // ProfileSettingsViewModel.shared via an inline binding, so no need to copy it
            // here. Image and name still flow through this view model and need forwarding.
            let settingsViewModel = ProfileSettingsViewModel.shared
            settingsViewModel.editingDisplayName = resolvedDisplayName
            settingsViewModel.profileImage = pendingProfileImage
            settingsViewModel.save()
            saveDisplayNameAsProfile = false
        }

        return didChange
    }

    private enum Constant {
        static let emojiMetadataKey: String = "emoji"
    }
}

extension MyProfileViewModel {
    static var mock: MyProfileViewModel {
        return .init(
            inboxId: "mock-inbox-id",
            messagingService: MockMessagingService(),
            myProfileRepository: MockMyProfileRepository()
        )
    }
}
