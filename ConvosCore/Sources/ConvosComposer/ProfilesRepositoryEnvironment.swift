#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// Injects the canonical `ProfilesRepository` into the SwiftUI environment so
/// avatar surfaces keyed by inbox id (see `InboxProfileAvatarView`) can
/// subscribe to unified profile changes without threading the session through
/// every view. Defaults to nil so previews and any uninjected subtree render a
/// placeholder rather than crashing.
private struct ProfilesRepositoryKey: EnvironmentKey {
    static let defaultValue: ProfilesRepository? = nil
}

public extension EnvironmentValues {
    var profilesRepository: ProfilesRepository? {
        get { self[ProfilesRepositoryKey.self] }
        set { self[ProfilesRepositoryKey.self] = newValue }
    }
}

public extension View {
    func profilesRepository(_ repository: ProfilesRepository?) -> some View {
        environment(\.profilesRepository, repository)
    }
}
#endif
