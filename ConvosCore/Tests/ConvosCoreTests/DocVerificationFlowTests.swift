@testable import ConvosCore
import Testing

@Suite("Doc verification flow")
struct DocVerificationFlowTests {
    @Test("moves from number to code and waits for the verified fact")
    func numberToVerified() {
        var state: DocVerificationFlowState = .enteringNumber

        state = reduce(state, .request(number: Fixture.number))
        #expect(state == .requesting(number: Fixture.number))

        state = reduce(state, .requestSent(number: Fixture.number))
        #expect(state == .enteringCode(number: Fixture.number, attemptFailed: false))

        state = reduce(state, .submitCode)
        #expect(state == .submitting(number: Fixture.number))

        state = reduce(state, .submissionVerified(number: Fixture.number))
        #expect(state == .awaitingVerification(number: Fixture.number))

        state = reduce(state, .verified(number: Fixture.number))
        #expect(state == .verified(number: Fixture.number))
    }

    @Test("send failure opens the text fallback")
    func sendFailedToFallback() {
        let requesting = reduce(.enteringNumber, .request(number: Fixture.number))
        let failed = reduce(requesting, .requestFailed(number: Fixture.number))

        #expect(failed == .fallback(number: Fixture.number))
    }

    @Test("failed code attempts return to an enabled retry")
    func attemptFailedRetry() {
        var state: DocVerificationFlowState = .enteringCode(
            number: Fixture.number,
            attemptFailed: false
        )

        state = reduce(state, .submitCode)
        state = reduce(state, .submissionFailed(number: Fixture.number))
        #expect(state == .enteringCode(number: Fixture.number, attemptFailed: true))

        state = reduce(state, .submitCode)
        #expect(state == .submitting(number: Fixture.number))
    }

    @Test("late request acknowledgments advance a timed out attempt")
    func acceptsLateRequestAcknowledgments() {
        var state: DocVerificationFlowState = .enteringNumber

        state = reduce(state, .request(number: Fixture.number))
        state = reduce(state, .requestAcknowledgmentTimedOut(number: Fixture.number))
        #expect(state == .requestTimedOut(number: Fixture.number))

        state = reduce(state, .requestSent(number: Fixture.number))
        #expect(state == .enteringCode(number: Fixture.number, attemptFailed: false))

        state = reduce(state, .request(number: Fixture.otherNumber))
        state = reduce(state, .requestSent(number: Fixture.number))
        #expect(state == .requesting(number: Fixture.otherNumber))

        state = reduce(state, .requestSent(number: Fixture.otherNumber))
        state = reduce(state, .requestSent(number: Fixture.otherNumber))
        #expect(state == .enteringCode(number: Fixture.otherNumber, attemptFailed: false))
    }

    @Test("late submission acknowledgments advance a timed out attempt")
    func acceptsLateSubmissionAcknowledgments() {
        var state: DocVerificationFlowState = .enteringCode(
            number: Fixture.number,
            attemptFailed: false
        )

        state = reduce(state, .submitCode)
        state = reduce(state, .submissionAcknowledgmentTimedOut(number: Fixture.number))
        #expect(state == .submissionTimedOut(number: Fixture.number))

        state = reduce(state, .submissionVerified(number: Fixture.number))
        #expect(state == .awaitingVerification(number: Fixture.number))
    }

    @Test("late submit failures cannot overwrite an enabled retry")
    func ignoresLateSubmitFailure() {
        var state: DocVerificationFlowState = .enteringCode(
            number: Fixture.number,
            attemptFailed: false
        )

        state = reduce(state, .submitCode)
        state = reduce(state, .submissionAcknowledgmentTimedOut(number: Fixture.number))
        #expect(state == .submissionTimedOut(number: Fixture.number))

        state = reduce(state, .submissionFailed(number: Fixture.number))
        #expect(state == .submissionTimedOut(number: Fixture.number))
    }

    @Test("normalizes locale-aware entry to E.164")
    func normalizesPhoneNumbers() {
        let unitedStates = DocPhoneNumberFormatter(regionCode: "US")
        let unitedKingdom = DocPhoneNumberFormatter(regionCode: "GB")

        #expect(unitedStates.e164(from: "(415) 555-0123") == "+14155550123")
        #expect(unitedStates.formatPartial("+14155550123") == "+1 (415) 555-0123")
        #expect(unitedKingdom.e164(from: "020 7946 0958") == "+442079460958")
        #expect(unitedKingdom.formatPartial("+442079460958") == "+44 20 7946 0958")
        #expect(unitedStates.e164(from: "123") == nil)
    }

    private func reduce(
        _ state: DocVerificationFlowState,
        _ event: DocVerificationFlowEvent
    ) -> DocVerificationFlowState {
        DocVerificationFlowReducer.reduce(state, event: event)
    }

    private enum Fixture {
        static let number: String = "+14155550123"
        static let otherNumber: String = "+442079460958"
    }
}
