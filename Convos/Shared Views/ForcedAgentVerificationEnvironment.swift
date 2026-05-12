import ConvosCore
import SwiftUI

/// Forces the conversation indicator/avatar to render with a specific
/// `AgentVerification` style regardless of the underlying conversation's
/// member data. Used by flows where the conversation is still a draft
/// but the avatar needs to advertise an upcoming assistant identity from
/// the moment the view appears (e.g. the Assistant Builder).
private struct ForcedAgentVerificationKey: EnvironmentKey {
    static let defaultValue: AgentVerification? = nil
}

extension EnvironmentValues {
    var forcedAgentVerification: AgentVerification? {
        get { self[ForcedAgentVerificationKey.self] }
        set { self[ForcedAgentVerificationKey.self] = newValue }
    }
}
