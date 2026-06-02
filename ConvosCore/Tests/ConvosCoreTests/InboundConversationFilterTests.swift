@testable import ConvosCore
import Foundation
import Testing

@Suite("InboundConversationFilter Tests", .serialized)
struct InboundConversationFilterTests {
    // The filter is a thin persistence gate: it drops only `.denied`
    // conversations. Feed visibility is decided downstream from the
    // stored consent state, not here.

    @Test(".allowed → deliver")
    func testAllowedDelivers() {
        let filter = InboundConversationFilter()
        #expect(filter.decide(consentState: .allowed) == .deliver)
    }

    @Test(".unknown → deliver (visibility decided at read time)")
    func testUnknownDelivers() {
        let filter = InboundConversationFilter()
        #expect(filter.decide(consentState: .unknown) == .deliver)
    }

    @Test(".denied → reject")
    func testDeniedRejects() {
        let filter = InboundConversationFilter()
        #expect(filter.decide(consentState: .denied) == .reject)
    }
}
