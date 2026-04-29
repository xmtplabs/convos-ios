@testable import ConvosCore
import Foundation
import Testing

@Suite("TerminalSessionError Tests")
struct TerminalSessionErrorTests {
    @Test("DeviceReplacedError conforms to TerminalSessionError")
    func testDeviceReplacedIsTerminal() {
        let error: any Error = DeviceReplacedError()
        #expect(error is TerminalSessionError)
    }

    @Test("Equality: DeviceReplacedError instances are always equal")
    func testDeviceReplacedEquality() {
        #expect(DeviceReplacedError() == DeviceReplacedError())
    }

    @Test("Non-terminal errors are not matched by the TerminalSessionError cast")
    func testNonTerminalErrorsAreNotMatched() {
        struct TransientError: Error {}
        let error: any Error = TransientError()
        #expect(!(error is TerminalSessionError))
    }
}
