import ConvosCore
import Foundation

extension SuggestedAgentsService {
    /// Builds the live service from the current environment's API client.
    /// Used by the new-conversation / compose entry points of
    /// `ContactsPickerView` to populate the "Suggested agents" section.
    static func live() -> SuggestedAgentsService {
        SuggestedAgentsService(
            apiClient: ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)
        )
    }
}
