import Foundation

public enum AssistantJoinStatus: String, Equatable, Hashable, Sendable, Codable {
    case pending
    case noAgentsAvailable // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    case failed
}
