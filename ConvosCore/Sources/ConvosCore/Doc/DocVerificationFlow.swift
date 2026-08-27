import Foundation

public enum DocVerificationFlowState: Equatable, Sendable {
    case enteringNumber
    case requesting(number: String)
    case requestTimedOut(number: String)
    case enteringCode(number: String, attemptFailed: Bool)
    case submitting(number: String)
    case submissionTimedOut(number: String)
    case awaitingVerification(number: String)
    case fallback(number: String)
    case verified(number: String?)

    public var number: String? {
        switch self {
        case .enteringNumber:
            nil
        case .requesting(let number),
             .requestTimedOut(let number),
             .enteringCode(let number, _),
             .submitting(let number),
             .submissionTimedOut(let number),
             .awaitingVerification(let number),
             .fallback(let number):
            number
        case .verified(let number):
            number
        }
    }
}

public enum DocVerificationFlowEvent: Equatable, Sendable {
    case request(number: String)
    case requestSent(number: String)
    case requestFailed(number: String)
    case requestTransportFailed
    case requestAcknowledgmentTimedOut(number: String)
    case submitCode
    case submissionVerified(number: String)
    case submissionFailed(number: String)
    case submissionTransportFailed(number: String)
    case submissionAcknowledgmentTimedOut(number: String)
    case showFallback
    case editNumber
    case verified(number: String?)
}

public enum DocVerificationFlowReducer {
    public static func reduce(
        _ state: DocVerificationFlowState,
        event: DocVerificationFlowEvent
    ) -> DocVerificationFlowState {
        switch event {
        case .request(let number):
            return .requesting(number: number)
        case .requestSent(let number):
            guard state == .requesting(number: number) || state == .enteringNumber else { return state }
            return .enteringCode(number: number, attemptFailed: false)
        case .requestFailed(let number):
            guard state == .requesting(number: number) ||
                state == .enteringNumber ||
                state == .enteringCode(number: number, attemptFailed: false) ||
                state == .enteringCode(number: number, attemptFailed: true) else {
                return state
            }
            return .fallback(number: number)
        case .requestTransportFailed:
            guard case .requesting = state else { return state }
            return .enteringNumber
        case .requestAcknowledgmentTimedOut(let number):
            guard state == .requesting(number: number) else { return state }
            return .requestTimedOut(number: number)
        case .submitCode:
            switch state {
            case .enteringCode(let number, _), .submissionTimedOut(let number):
                return .submitting(number: number)
            default:
                return state
            }
        case .submissionVerified(let number):
            guard state == .submitting(number: number) else { return state }
            return .awaitingVerification(number: number)
        case .submissionFailed(let number):
            guard state == .submitting(number: number) ||
                state == .awaitingVerification(number: number) ||
                state == .enteringCode(number: number, attemptFailed: false) else {
                return state
            }
            return .enteringCode(number: number, attemptFailed: true)
        case .submissionTransportFailed(let number):
            guard state == .submitting(number: number) || state == .awaitingVerification(number: number) else {
                return state
            }
            return .enteringCode(number: number, attemptFailed: false)
        case .submissionAcknowledgmentTimedOut(let number):
            guard state == .submitting(number: number) else { return state }
            return .submissionTimedOut(number: number)
        case .showFallback:
            guard let number = state.number else { return state }
            return .fallback(number: number)
        case .editNumber:
            return .enteringNumber
        case .verified(let number):
            return .verified(number: number)
        }
    }
}
