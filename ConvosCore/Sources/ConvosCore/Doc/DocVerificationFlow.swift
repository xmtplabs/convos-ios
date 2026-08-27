import Foundation

public enum DocVerificationFlowState: Equatable, Sendable {
    case enteringNumber
    case requesting(number: String)
    case enteringCode(number: String, attemptFailed: Bool)
    case submitting(number: String)
    case awaitingVerification(number: String)
    case fallback(number: String)
    case verified(number: String?)

    public var number: String? {
        switch self {
        case .enteringNumber:
            nil
        case .requesting(let number),
             .enteringCode(let number, _),
             .submitting(let number),
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
    case submitCode
    case submissionVerified(number: String)
    case submissionFailed(number: String)
    case submissionTransportFailed(number: String)
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
            return .enteringCode(number: number, attemptFailed: false)
        case .requestFailed(let number):
            return .fallback(number: number)
        case .requestTransportFailed:
            return .enteringNumber
        case .submitCode:
            guard case .enteringCode(let number, _) = state else { return state }
            return .submitting(number: number)
        case .submissionVerified(let number):
            return .awaitingVerification(number: number)
        case .submissionFailed(let number):
            return .enteringCode(number: number, attemptFailed: true)
        case .submissionTransportFailed(let number):
            return .enteringCode(number: number, attemptFailed: false)
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
