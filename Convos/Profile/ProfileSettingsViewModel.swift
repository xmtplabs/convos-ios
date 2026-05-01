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
        repository.myGlobalProfilePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] profile in
                guard let self else { return }
                self.editingDisplayName = profile?.name ?? ""
                self.profileImage = profile?.imageData.flatMap(UIImage.init(data:))
            }
            .store(in: &cancellables)
    }

    func save() {
        guard let writer else {
            Log.error("ProfileSettingsViewModel.save called before bind")
            return
        }
        let trimmedName = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String? = trimmedName.isEmpty ? nil : trimmedName
        let imageData = profileImage?.jpegData(compressionQuality: 1.0)
        let isDefault = profileSettings.isDefault
        Task {
            do {
                try await writer.save(
                    name: resolvedName,
                    imageData: imageData,
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
