import Foundation

// MARK: - CommitLogForkStatus

public enum CommitLogForkStatus: String, Codable, Hashable, Sendable {
    case forked, notForked = "not_forked", unknown
}
