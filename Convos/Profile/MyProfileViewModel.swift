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
    private var pendingUpdateCount: Int = 0

    var isEditingDisplayName: Bool = false
    var editingDisplayName: String = ""
    var saveDisplayNameAsQuickname: Bool = false

    var profileImage: UIImage?

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
                self?.profileImage = ImageCache.shared.image(for: profile)
                self?.profile = profile
            }
            .store(in: &cancellables)
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
        nonisolated(unsafe) let unsafeWriter = myProfileWriter
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

    private func update(profileImage: UIImage, conversationId: String) {
        self.profileImage = profileImage
        ImageCache.shared.setImage(profileImage, for: profile)

        updateImageTask?.cancel()
        beginUpdate()
        let displayNameTask = updateDisplayNameTask
        nonisolated(unsafe) let unsafeWriter = myProfileWriter
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
        let latestProfile = try? myProfileRepository.fetch()
        if latestProfile == nil || latestProfile?.name != trimmedDisplayName {
            update(displayName: trimmedDisplayName, conversationId: conversationId)
            didChange = true
        }

        // @jarodl check if the image was actually changed
        if let profileImage {
            update(profileImage: profileImage, conversationId: conversationId)
            didChange = true
            self.profileImage = nil
        }

        if saveDisplayNameAsQuickname {
            let current = QuicknameSettings.current()
                .with(displayName: trimmedDisplayName)
                .with(profileImage: profileImage)
            do {
                try current.save()
            } catch {
                Log.error("Error saving profile as Quickname: \(error.localizedDescription)")
            }
            saveDisplayNameAsQuickname = false
        }

        return didChange
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
