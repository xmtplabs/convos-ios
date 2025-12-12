import Foundation

// MARK: - Consent

public enum Consent: String, Codable, Hashable, CaseIterable, Sendable {
    case allowed, denied, unknown
}

public extension Array where Element == Consent {
    static var all: [Consent] {
        Consent.allCases
    }

    static var allowed: [Consent] {
        [.allowed]
    }

    static var denied: [Consent] {
        [.denied]
    }

    static var securityLine: [Consent] {
        [.unknown]
    }
}
