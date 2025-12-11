import Foundation

// MARK: - ConversationDebugInfo

public struct ConversationDebugInfo: Codable, Hashable, Sendable {
    public let epoch: UInt64
    public let maybeForked: Bool
    public let forkDetails: String
    public let localCommitLog: String
    public let remoteCommitLog: String
    public let commitLogForkStatus: CommitLogForkStatus

    public init(
        epoch: UInt64,
        maybeForked: Bool,
        forkDetails: String,
        localCommitLog: String,
        remoteCommitLog: String,
        commitLogForkStatus: CommitLogForkStatus
    ) {
        self.epoch = epoch
        self.maybeForked = maybeForked
        self.forkDetails = forkDetails
        self.localCommitLog = localCommitLog
        self.remoteCommitLog = remoteCommitLog
        self.commitLogForkStatus = commitLogForkStatus
    }

    public static var empty: Self {
        .init(
            epoch: 0,
            maybeForked: false,
            forkDetails: "",
            localCommitLog: "",
            remoteCommitLog: "",
            commitLogForkStatus: .unknown
        )
    }
}
