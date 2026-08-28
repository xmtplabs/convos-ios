@testable import ConvosCore
import Testing
import UserNotifications

@Suite("AgentRelay notification content")
struct AgentRelayNotificationContentTests {
    @Test("unattributable collection preserves the original push")
    func unattributableCollectionPreservesOriginalPush() {
        let original = UNMutableNotificationContent()
        original.title = "Your agent replied"
        original.body = "Open Convos to see the result."
        original.sound = .default
        original.threadIdentifier = "backend-thread"

        let content = AgentRelayNotificationContent.content(
            for: .collected(nil),
            original: original,
            provider: nil
        )

        #expect(content === original)
        #expect(content.title == "Your agent replied")
        #expect(content.body == "Open Convos to see the result.")
        #expect(content.sound != nil)
        #expect(content.threadIdentifier == "backend-thread")
    }
}
