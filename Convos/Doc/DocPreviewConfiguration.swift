import Foundation

enum DocPreviewConfiguration {
    /// Fixed shared Photon line for the Doc dev preview. State can override it.
    static let contributionLine: String = "+16283095734"
    static let avatarEmoji: String = "📄"
}

enum DocContributionLinePolicy {
    static func number(stateLine: String?) -> String {
        let stateLine = stateLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stateLine, !stateLine.isEmpty else {
            return DocPreviewConfiguration.contributionLine
        }
        return stateLine
    }
}
