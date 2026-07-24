#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// Forces the conversation indicator/avatar to render with a specific
/// `AgentVerification` style regardless of the underlying conversation's
/// member data. Used by flows where the conversation is still a draft
/// but the avatar needs to advertise an upcoming agent identity from
/// the moment the view appears (e.g. the Agent Builder).
private struct ForcedAgentVerificationKey: EnvironmentKey {
    static let defaultValue: AgentVerification? = nil
}

public extension EnvironmentValues {
    var forcedAgentVerification: AgentVerification? {
        get { self[ForcedAgentVerificationKey.self] }
        set { self[ForcedAgentVerificationKey.self] = newValue }
    }
}
#endif
