import ConvosCore
import Foundation

extension PromptHintsService {
    /// Builds the live service from the current environment's API client.
    /// Mirrors `SuggestedAgentsService.live()`. Used by `MainTabView` to
    /// prewarm the agent builder's dice hints once on launch.
    static func live() -> PromptHintsService {
        PromptHintsService(
            apiClient: ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)
        )
    }
}

extension PromptHintsModel {
    /// Live model backed by the environment's API client. Hydrates from disk
    /// synchronously in `init`; the network refresh is kicked off by
    /// `loadOnLaunch()` from `MainTabView`'s launch task.
    static func live() -> PromptHintsModel {
        PromptHintsModel(service: PromptHintsService.live())
    }

    /// Preview/test helper: an in-memory model pre-seeded with `hints` (via a
    /// fake disk cache) so the dice control renders without a network round-trip.
    static func preview(hints: [String] = MockPromptHintsService.defaultHints) -> PromptHintsModel {
        PromptHintsModel(
            service: MockPromptHintsService(hints: hints),
            store: PromptHintsDiskCache(load: { hints }, save: { _ in })
        )
    }
}
