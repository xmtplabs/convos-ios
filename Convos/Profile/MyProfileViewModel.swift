import Combine
import ConvosCore
import SwiftUI

@MainActor
@Observable
class MyProfileViewModel {
    private let myProfileWriter: any MyProfileWriterProtocol
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
        myProfileWriter: any MyProfileWriterProtocol,
        myProfileRepository: any MyProfileRepositoryProtocol
    ) {
        self.profile = .empty(inboxId: inboxId)
        self.myProfileWriter = myProfileWriter
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
    /// Prefers the in-memory global image when one of:
    ///   - The per-conversation member has no avatar yet (nothing to show otherwise).
    ///   - The per-conversation member's `imageSourceContentDigest` matches the current
    ///     global digest, meaning the per-conversation avatar was uploaded *from* the same
    ///     global photo we hold in memory. In that case the in-memory image is identical
    ///     to what the per-conversation cache would eventually load, and using it directly
    ///     avoids the flicker between an old cached image and a new uploaded one while
    ///     activate-sync replaces the per-conversation avatar.
    /// Otherwise falls back to the per-conversation cache, preserving any future
    /// per-conversation override.
    private static func preferredImage(for profile: Profile) -> UIImage? {
        let global = ProfileSettingsViewModel.shared
        if profile.avatar == nil {
            return global.profileImage
        }
        if let memberDigest = profile.imageSourceContentDigest,
           let globalDigest = global.profileImageContentDigest,
           memberDigest == globalDigest,
           global.profileImage != nil {
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
        let unsafeWriter = myProfileWriter
        updateDisplayNameTask = Task { [weak self] in
            guard self != nil else { return }
            defer { Task { @MainActor [weak self] in self?.endUpdate() } }
            do {
                try await unsafeWriter.update(displayName: displayName, conversationId: conversationId)
            } catch {
                Log.error("Error updating profile display name: \(error.localizedDescription)")
            }
        }
    }

    private func update(profileMetadata: ProfileMetadata?, conversationId: String) {
        updateMetadataTask?.cancel()
        beginUpdate()
        let displayNameTask = updateDisplayNameTask
        let unsafeWriter = myProfileWriter
        updateMetadataTask = Task { [weak self] in
            guard self != nil else { return }
            defer { Task { @MainActor [weak self] in self?.endUpdate() } }
            await displayNameTask?.value
            do {
                try await unsafeWriter.update(metadata: profileMetadata, conversationId: conversationId)
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
        let unsafeWriter = myProfileWriter
        updateImageTask = Task { [weak self] in
            guard self != nil else { return }
            defer { Task { @MainActor [weak self] in self?.endUpdate() } }
            // Wait for any pending display name update to complete first,
            // so the avatar update reads the profile with the correct name
            await displayNameTask?.value
            do {
                try await unsafeWriter.update(avatar: profileImage, conversationId: conversationId)
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
        if latestProfile == nil || latestProfile?.name != trimmedDisplayName {
            update(displayName: trimmedDisplayName, conversationId: conversationId)
            didChange = true
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
            settingsViewModel.editingDisplayName = trimmedDisplayName
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
            myProfileWriter: MockMyProfileWriter(),
            myProfileRepository: MockMyProfileRepository()
        )
    }
}
