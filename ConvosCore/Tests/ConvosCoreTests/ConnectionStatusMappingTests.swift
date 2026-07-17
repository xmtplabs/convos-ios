@testable import ConvosCore
import Foundation
import Testing

@Suite("CloudConnectionStatus Composio mapping Tests")
struct ConnectionStatusMappingTests {
    @Test("ACTIVE maps to .active")
    func activeMaps() {
        #expect(CloudConnectionStatus.from(composioStatus: "ACTIVE") == .active)
    }

    @Test("INITIATED and INITIALIZING map to .active (pre-complete states)")
    func preCompleteStates() {
        #expect(CloudConnectionStatus.from(composioStatus: "INITIATED") == .active)
        #expect(CloudConnectionStatus.from(composioStatus: "INITIALIZING") == .active)
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
