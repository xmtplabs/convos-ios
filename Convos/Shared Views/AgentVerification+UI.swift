import ConvosCore
import SwiftUI

extension AgentVerification {
    var avatarBackgroundColor: Color {
        switch self {
        case .unverified:
            return .colorFillTertiary
        case .verified(let issuer):
            switch issuer {
            case .convos:
                return .colorLava
            case .userOAuth:
                return .colorPurpleMute
            case .unknown:
                return .colorFillSecondary
            }
        }
    }

    var nameColor: Color {
        switch self {
        case .unverified:
            return .secondary
        case .verified(let issuer):
            switch issuer {
            case .convos:
                return .colorLava
            case .userOAuth:
                return .colorPurpleMute
            case .unknown:
                return .colorFillSecondary
            }
        }
    }

    var roleLabel: String? {
        switch self {
        case .unverified:
            return nil
        case .verified(let issuer):
            switch issuer {
            case .convos:
                return "Assistant"
            case .userOAuth:
                return "Verified Agent"
            case .unknown:
                return "Verified Agent"
            }
        }
    }
}
