@testable import ConvosConnections
import Testing

@Suite("ConnectionKind")
struct ConnectionKindTests {
    @Test("raw values are stable")
    func rawValuesAreStable() {
        #expect(ConnectionKind.health.rawValue == "health")
        #expect(ConnectionKind.homeKit.rawValue == "home_kit")
        #expect(ConnectionKind.screenTime.rawValue == "screen_time")
    }

    @Test("every case has a display name and system image")
    func everyCaseHasDisplayMetadata() {
        for kind in ConnectionKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.systemImageName.isEmpty)
        }
    }
}
