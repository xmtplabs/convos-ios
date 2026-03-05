@testable import ConvosCore
import Foundation
import Testing

@Suite("PairingCoordinator Tests")
struct PairingCoordinatorTests {
    @Test("Generate confirmation code is 6 digits")
    func generateCode() {
        let code = PairingCoordinator.generateConfirmationCode()
        #expect(code.count == 6)
        let allDigits = code.allSatisfy(\.isNumber)
        #expect(allDigits)
    }

    @Test("Generate confirmation code produces different codes")
    func generateCodeUnique() {
        let codes = Set((0 ..< 20).map { _ in PairingCoordinator.generateConfirmationCode() })
        #expect(codes.count > 1)
    }

    @Test("Validate correct code")
    func validateCorrectCode() {
        let coordinator = PairingCoordinator()
        #expect(coordinator.validateConfirmationCode("482916", expected: "482916") == true)
    }

    @Test("Validate wrong code")
    func validateWrongCode() {
        let coordinator = PairingCoordinator()
        #expect(coordinator.validateConfirmationCode("000000", expected: "482916") == false)
    }

    @Test("Validate code with spaces stripped")
    func validateCodeWithSpaces() {
        let coordinator = PairingCoordinator()
        #expect(coordinator.validateConfirmationCode("482 916", expected: "482916") == true)
    }

    @Test("Validate code with dashes stripped")
    func validateCodeWithDashes() {
        let coordinator = PairingCoordinator()
        #expect(coordinator.validateConfirmationCode("482-916", expected: "482916") == true)
    }

    @Test("Validate empty code")
    func validateEmptyCode() {
        let coordinator = PairingCoordinator()
        #expect(coordinator.validateConfirmationCode("", expected: "482916") == false)
    }

    @Test("Validate partial code")
    func validatePartialCode() {
        let coordinator = PairingCoordinator()
        #expect(coordinator.validateConfirmationCode("482", expected: "482916") == false)
    }

    @Test("Validate too long code")
    func validateTooLongCode() {
        let coordinator = PairingCoordinator()
        #expect(coordinator.validateConfirmationCode("4829160", expected: "482916") == false)
    }

    @Test("PairingError descriptions")
    func errorDescriptions() {
        let errors: [PairingError] = [
            .notConnected,
            .invalidConfirmationCode,
            .pairingTimeout,
            .alreadyPairing,
            .noVaultGroup,
        ]
        for error in errors {
            let description = error.errorDescription
            #expect(description != nil)
            #expect(description?.isEmpty == false)
        }
    }

    @Test("PairingState idle")
    func stateIdle() {
        let state: PairingState = .idle
        if case .idle = state {
            // correct
        } else {
            Issue.record("Expected idle state")
        }
    }

    @Test("PairingState waitingForScan")
    func stateWaitingForScan() {
        let state: PairingState = .waitingForScan(code: "123456", inviteURL: "https://convos.org/i/abc")
        if case let .waitingForScan(code, url) = state {
            #expect(code == "123456")
            #expect(url == "https://convos.org/i/abc")
        } else {
            Issue.record("Expected waitingForScan state")
        }
    }

    @Test("PairingState completed")
    func stateCompleted() {
        let state: PairingState = .completed(deviceCount: 3)
        if case let .completed(count) = state {
            #expect(count == 3)
        } else {
            Issue.record("Expected completed state")
        }
    }

    @Test("Custom timeout configuration")
    func customTimeout() {
        let coordinator = PairingCoordinator(timeoutSeconds: 60)
        _ = coordinator
    }
}
