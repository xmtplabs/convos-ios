@testable import ConvosCore
import Foundation
import Testing

@Suite("ConnectionStatus Composio mapping Tests")
struct ConnectionStatusMappingTests {
    @Test("ACTIVE maps to .active")
    func activeMaps() {
        #expect(ConnectionStatus.from(composioStatus: "ACTIVE") == .active)
    }

    @Test("INITIATED and INITIALIZING map to .active (pre-complete states)")
    func preCompleteStates() {
        #expect(ConnectionStatus.from(composioStatus: "INITIATED") == .active)
        #expect(ConnectionStatus.from(composioStatus: "INITIALIZING") == .active)
    }

    @Test("EXPIRED maps to .expired")
    func expiredMaps() {
        #expect(ConnectionStatus.from(composioStatus: "EXPIRED") == .expired)
    }

    @Test("FAILED and INACTIVE map to .revoked")
    func revokedMaps() {
        #expect(ConnectionStatus.from(composioStatus: "FAILED") == .revoked)
        #expect(ConnectionStatus.from(composioStatus: "INACTIVE") == .revoked)
    }

    @Test("Unknown Composio status defaults to .expired (safer than .active)")
    func unknownDefaultsToExpired() {
        #expect(ConnectionStatus.from(composioStatus: "BLOCKED") == .expired)
        #expect(ConnectionStatus.from(composioStatus: "SOMETHING_NEW") == .expired)
        #expect(ConnectionStatus.from(composioStatus: "") == .expired)
    }

    @Test("Status mapping is case-insensitive")
    func caseInsensitive() {
        #expect(ConnectionStatus.from(composioStatus: "active") == .active)
        #expect(ConnectionStatus.from(composioStatus: "Active") == .active)
        #expect(ConnectionStatus.from(composioStatus: "failed") == .revoked)
    }
}
