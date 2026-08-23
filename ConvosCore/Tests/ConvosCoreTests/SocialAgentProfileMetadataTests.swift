import Foundation
import Testing
@testable import ConvosCore

@Suite("Social agent profile metadata")
struct SocialAgentProfileMetadataTests {
    @Test("Providers stay private until visibility is enabled")
    func providersRequireOptIn() {
        let metadata: ProfileMetadata = [
            SocialAgentProfileMetadata.providerIdsKey: .string("codex,town"),
        ]

        #expect(SocialAgentProfileMetadata.providerIds(from: metadata).isEmpty)
    }

    @Test("Publishing preserves order and removes duplicate provider ids")
    func providersAreSanitized() {
        var metadata: ProfileMetadata = ["emoji": .string("🌎")]

        SocialAgentProfileMetadata.update(
            &metadata,
            isVisible: true,
            providerIds: [" codex ", "town", "codex", ""]
        )

        #expect(SocialAgentProfileMetadata.providerIds(from: metadata) == ["codex", "town"])
        #expect(metadata["emoji"] == .string("🌎"))
    }

    @Test("Turning visibility off removes provider identity and preserves other metadata")
    func disablingRemovesProviderIdentity() {
        var metadata: ProfileMetadata = [
            "emoji": .string("🌎"),
            SocialAgentProfileMetadata.visibilityKey: .bool(true),
            SocialAgentProfileMetadata.providerIdsKey: .string("codex,town"),
        ]

        SocialAgentProfileMetadata.update(
            &metadata,
            isVisible: false,
            providerIds: ["codex", "town"]
        )

        #expect(metadata[SocialAgentProfileMetadata.visibilityKey] == .bool(false))
        #expect(metadata[SocialAgentProfileMetadata.providerIdsKey] == nil)
        #expect(metadata["emoji"] == .string("🌎"))
    }
}
