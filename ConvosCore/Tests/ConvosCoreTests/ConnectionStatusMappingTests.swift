@testable import ConvosCore
import Foundation
import Testing

@Suite("CloudConnectionStatus Composio mapping Tests")
struct ConnectionStatusMappingTests {
    @Test("ACTIVE maps to .active")
    func activeMaps() {
        #expect(CloudConnectionStatus.from(composioStatus: "ACTIVE") == .active)
    }

    @Test("INITIATED and INITIALIZING are not active (OAuth never completed)")
    func preCompleteStatesAreNotActive() {
        // An OAuth that was started but never completed must not read as a
        // connected account: treating these as active minted phantom-linked
        // providers the approval sheet trusted, skipping its OAuth leg
        // entirely. Expired surfaces the (re)connect prompt.
        #expect(CloudConnectionStatus.from(composioStatus: "INITIATED") == .expired)
        #expect(CloudConnectionStatus.from(composioStatus: "INITIALIZING") == .expired)
        #expect(CloudConnectionStatus.from(composioStatus: "initiated") == .expired)
    }

    @Test("EXPIRED maps to .expired")
    func expiredMaps() {
        #expect(CloudConnectionStatus.from(composioStatus: "EXPIRED") == .expired)
    }

    @Test("FAILED and INACTIVE map to .revoked")
    func revokedMaps() {
        #expect(CloudConnectionStatus.from(composioStatus: "FAILED") == .revoked)
        #expect(CloudConnectionStatus.from(composioStatus: "INACTIVE") == .revoked)
    }

    @Test("Unknown Composio status defaults to .expired (safer than .active)")
    func unknownDefaultsToExpired() {
        #expect(CloudConnectionStatus.from(composioStatus: "BLOCKED") == .expired)
        #expect(CloudConnectionStatus.from(composioStatus: "SOMETHING_NEW") == .expired)
        #expect(CloudConnectionStatus.from(composioStatus: "") == .expired)
    }

    @Test("Status mapping is case-insensitive")
    func caseInsensitive() {
        #expect(CloudConnectionStatus.from(composioStatus: "active") == .active)
        #expect(CloudConnectionStatus.from(composioStatus: "Active") == .active)
        #expect(CloudConnectionStatus.from(composioStatus: "failed") == .revoked)
    }
}
