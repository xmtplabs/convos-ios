import ConvosAppData
@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

@Suite("Creator Metadata Participation Mode Tests")
struct EnsureCreatorMetadataParticipationTests {
    private enum TestError: Error {
        case missingClients
    }

    @Test("ensureCreatorMetadata seeds Listen as the initial participation mode")
    func seedsListenParticipationMode() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        #expect(try group.participationMode == nil)

        try await group.ensureCreatorMetadata(emojiSeed: "seed")

        #expect(try group.participationMode == .mentionsOnly)

        try? await fixtures.cleanup()
    }

    @Test("ensureCreatorMetadata leaves an already-set participation mode untouched")
    func preservesExistingParticipationMode() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        try await group.updateParticipationMode(.paused)
        #expect(try group.participationMode == .paused)

        try await group.ensureCreatorMetadata(emojiSeed: "seed")

        #expect(try group.participationMode == .paused)

        try? await fixtures.cleanup()
    }

    @Test("ensureCreatorMetadata does not seed a mode on an already-established group")
    func doesNotSeedModeOnEstablishedGroup() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB else {
            throw TestError.missingClients
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        // A legacy creator-owned group: the invite tag is already authored, but
        // no participation mode was ever set. Re-running ensureCreatorMetadata
        // (as StreamProcessor does on reprocessing) must not flip it to Listen.
        try await group.ensureInviteTag()
        #expect(try group.participationMode == nil)

        try await group.ensureCreatorMetadata(emojiSeed: "seed")

        #expect(try group.participationMode == nil)

        try? await fixtures.cleanup()
    }
}
