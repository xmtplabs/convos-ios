@testable import ConvosCore
import Foundation
import Testing

/// Marker protocol contract for session errors that must not retry.
///
/// The short-circuit logic lives in
/// `SessionStateMachine.handleRetryFromError` and is exercised by
/// the XMTP-backed integration tests when a real revoked
/// installation is simulated. This suite pins the type-level
/// shape so a future rename or accidentally-broken conformance
/// surfaces as a focused failure rather than an opaque
/// integration-test flake.
@Suite("TerminalSessionError contract")
struct TerminalSessionErrorTests {
    @Test("DeviceReplacedError conforms to TerminalSessionError")
    func testDeviceReplacedConforms() {
        let error: any Error = DeviceReplacedError()
        #expect(error is TerminalSessionError)
    }

    @Test("DeviceReplacedError is Equatable")
    func testDeviceReplacedEquatable() {
        #expect(DeviceReplacedError() == DeviceReplacedError())
    }

    @Test("generic Error does not conform to TerminalSessionError")
    func testGenericErrorDoesNotConform() {
        struct NonTerminal: Error {}
        let error: any Error = NonTerminal()
        #expect(!(error is TerminalSessionError))
    }
}
