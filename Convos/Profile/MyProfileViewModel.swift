import Combine
import ConvosCore
import SwiftUI

@Observable
class MyProfileViewModel {
    private let myProfileWriter: any MyProfileWriterProtocol
    private let myProfileRepository: any MyProfileRepositoryProtocol
    private(set) var profile: Profile
    private var cancellables: Set<AnyCancellable> = []
    private var updateDisplayNameTask: Task<Void, Never>?
    private var updateImageTask: Task<Void, Never>?

    var isEditingDisplayName: Bool = false
    var editingDisplayName: String = ""

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

    deinit {
        cancellables.removeAll()
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
                self?.profile = profile
            }
            .store(in: &cancellables)
    }

    private func update(displayName: String, conversationId: String) {
        editingDisplayName = displayName
        updateDisplayNameTask?.cancel()
        updateDisplayNameTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await myProfileWriter.update(displayName: displayName, conversationId: conversationId)
            } catch {
                Log.error("Error updating profile display name: \(error.localizedDescription)")
            }
        }
    }

    private func update(profileImage: UIImage, conversationId: String) {
        self.profileImage = profileImage
        ImageCache.shared.setImage(profileImage, for: profile)

        updateImageTask?.cancel()
        updateImageTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await myProfileWriter.update(avatar: profileImage, conversationId: conversationId)
            } catch {
                Log.error("Error updating profile image: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Public

    func update(using profile: Profile, profileImage: UIImage?, conversationId: String) {
        self.profile = profile.with(inboxId: profile.inboxId)
        update(displayName: profile.displayName, conversationId: conversationId)
        if let profileImage = profileImage {
            update(profileImage: profileImage, conversationId: conversationId)
        }
    }

    func onEndedEditing(for conversationId: String) {
        let trimmedDisplayName = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let latestProfile = try? myProfileRepository.fetch()
        if latestProfile == nil || latestProfile?.name != trimmedDisplayName {
            update(displayName: trimmedDisplayName, conversationId: conversationId)
        }

        // @jarodl check if the image was actually changed
        if let profileImage {
            update(profileImage: profileImage, conversationId: conversationId)
        }
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
