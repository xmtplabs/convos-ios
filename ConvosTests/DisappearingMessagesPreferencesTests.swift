@testable import Convos
import ConvosCore
import XCTest

final class DisappearingMessagesPreferencesTests: XCTestCase {
    func testAgentPauseDefaultsToTwentyFourHours() {
        let conversationId = UUID().uuidString

        XCTAssertEqual(
            DisappearingMessagesPreferences.durationWhenAgentsPause(conversationId: conversationId),
            .twentyFourHours
        )
    }

    func testAgentPauseUsesTheLastSelectedTimer() {
        let conversationId = UUID().uuidString
        DisappearingMessagesPreferences.remember(.sevenDays, conversationId: conversationId)

        XCTAssertEqual(
            DisappearingMessagesPreferences.durationWhenAgentsPause(conversationId: conversationId),
            .sevenDays
        )
    }
}
