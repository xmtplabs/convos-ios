import ConvosCore
import ConvosMetrics
import XCTest
@testable import Convos

@MainActor
final class MetricsEmissionTests: XCTestCase {
    func testCoreMetricsStartedConversationEmitsSendEvent() async {
        let stub = StubMetricsCollector()
        let metrics = CoreMetrics(delegate: stub)

        await metrics.actions.startedConversation()

        XCTAssertEqual(stub.eventNames(), [MetricsCoreActions.eventStartedConversation])
    }

    func testCoreMetricsSentMessageEmitsSendEventWithProperties() async {
        let stub = StubMetricsCollector()
        let metrics = CoreMetrics(delegate: stub)

        await metrics.actions.sentMessage(
            sendingTime: 0.42,
            memberCount: 3,
            attachmentTypes: ["image"],
            hasText: true,
            hasAssistant: false,
            isSuccess: true
        )

        let events = stub.events(named: MetricsCoreActions.eventSentMessage)
        XCTAssertEqual(events.count, 1)

        let properties = events.first?.properties ?? [:]
        XCTAssertEqual(properties[MetricsCoreActions.paramMemberCount] as? Int, 3)
        XCTAssertEqual(properties[MetricsCoreActions.paramHasText] as? Bool, true)
        XCTAssertEqual(properties[MetricsCoreActions.paramHasAssistant] as? Bool, false)
        XCTAssertEqual(properties[MetricsCoreActions.paramIsSuccess] as? Bool, true)
        XCTAssertEqual(properties[MetricsCoreActions.paramAttachmentTypes] as? [String], ["image"])
    }

    func testCoreMetricsInvitedToConversationEmitsEvent() async {
        let stub = StubMetricsCollector()
        let metrics = CoreMetrics(delegate: stub)

        await metrics.actions.invitedToConversation(memberCount: 5, hasAssistant: true)

        let events = stub.events(named: MetricsCoreActions.eventInvitedToConversation)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.properties[MetricsCoreActions.paramMemberCount] as? Int, 5)
        XCTAssertEqual(events.first?.properties[MetricsCoreActions.paramHasAssistant] as? Bool, true)
    }

    func testCoreMetricsAddedAssistantEmitsEvent() async {
        let stub = StubMetricsCollector()
        let metrics = CoreMetrics(delegate: stub)

        await metrics.actions.addedAssistant(memberCount: 4)

        let events = stub.events(named: MetricsCoreActions.eventAddedAssistant)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.properties[MetricsCoreActions.paramMemberCount] as? Int, 4)
    }

    func testNavigationCollectorEmitsNavigatedToEvent() {
        let stub = StubMetricsCollector()
        let session = MockInboxesService()
        let navState = ConversationsNavigatorImpl(session: session, metricsDelegate: stub)
        let navigator: any ConversationsNavigator = ConversationsCollector(
            instance: navState,
            delegate: stub
        )

        navigator.navigateTo(conversation: ConversationNavigatorArgs(conversationId: "abc"))

        XCTAssertEqual(
            stub.navigations,
            [StubMetricsCollector.NavigationEvent(
                source: ConversationsCollector.name,
                target: ConversationCollector.name
            )]
        )
    }

    func testNavigationCollectorEmitsPresentNewConversationEvent() {
        let stub = StubMetricsCollector()
        let session = MockInboxesService()
        let navState = ConversationsNavigatorImpl(session: session, metricsDelegate: stub)
        let navigator: any ConversationsNavigator = ConversationsCollector(
            instance: navState,
            delegate: stub
        )

        navigator.present(newConversation: NewConversationNavigatorArgs(mode: .create))

        XCTAssertEqual(
            stub.presentations,
            [StubMetricsCollector.PresentEvent(
                source: ConversationsCollector.name,
                target: NewConversationCollector.name
            )]
        )
    }

    func testNavigationCollectorEmitsCloseEvent() {
        let stub = StubMetricsCollector()
        let session = MockInboxesService()
        let navState = ConversationsNavigatorImpl(session: session, metricsDelegate: stub)
        let navigator: any ConversationsNavigator = ConversationsCollector(
            instance: navState,
            delegate: stub
        )

        navigator.closed(context: ScreenContext(durationSecs: 1.5))

        XCTAssertEqual(stub.closes.count, 1)
        XCTAssertEqual(stub.closes.first?.screen, ConversationsCollector.name)
        XCTAssertEqual(stub.closes.first?.durationSecs, 1.5)
    }

    func testCollectorDelegateIdentifyAndUserPropertiesRecord() async {
        let stub = StubMetricsCollector()
        let metrics = CoreMetrics(delegate: stub)

        metrics.identify(userId: "user-123")
        await metrics.updateUserProperties(properties: UserProperties(
            hasMessagedAssistant: true,
            lastAssistantMessageTimestamp: "2026-05-07T00:00:00Z",
            contactCount: 1,
            conversationCount: 2,
            assistantConversationCount: 0,
            conversationCount24Hours: 1,
            conversationCount7Days: 1,
            maxActiveConvoAge: 0
        ))

        XCTAssertEqual(stub.identifies, ["user-123"])
        XCTAssertEqual(stub.userProperties.count, 1)
        XCTAssertEqual(
            stub.userProperties.first?.properties[CoreMetrics.userPropertyHasMessagedAssistant] as? Bool,
            true
        )
    }
}
