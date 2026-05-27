@testable import ConvosCore
import Foundation
import Testing

@Suite("InboundConversationFilter Tests", .serialized)
struct InboundConversationFilterTests {
    // Visibility used to be a third decision (`.quarantine`) here. That
    // moved to `DBConversation.visibleInFeedPredicate` — a live join
    // the `ConversationsRepository` runs at read time. The filter is
    // now a thin gate that drops only `.denied` conversations.

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
