import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS -> `MessagingConversationDebugInfo` boundary mappers, plus
/// the XMTPiOS-side `exportDebugLogs()` shim that goes through the
/// abstraction. The serialisation / file-writing behaviour lives on
/// `MessagingConversation.exportDebugLogs()` (see
/// `Messaging/Protocols/MessagingConversation.swift`); this file only
/// holds the XMTPiOS-aware glue.
extension XMTPiOS.Conversation {
    /// Wraps the XMTPiOS-native group/dm debug call behind the
    /// messaging-protocol value type. This is the only XMTPiOS-aware
    /// surface the Convos-side code needs for debug export.
    public func exportDebugLogs() async throws -> URL {
        let debugInfo: MessagingConversationDebugInfo
        switch self {
        case .group(let group):
            debugInfo = MessagingConversationDebugInfo(try await group.getDebugInformation())
        case .dm(let dm):
            debugInfo = MessagingConversationDebugInfo(try await dm.getDebugInformation())
        }

        let payload: [String: Any] = [
            "conversationId": id,
            "epoch": debugInfo.epoch,
            "maybeForked": debugInfo.maybeForked,
            "forkDetails": debugInfo.forkDetails,
            "localCommitLog": debugInfo.localCommitLog,
            "remoteCommitLog": debugInfo.remoteCommitLog,
            "commitLogForkStatus": String(describing: debugInfo.commitLogForkStatus)
        ]
        let jsonData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )

        let tempDir = FileManager.default.temporaryDirectory
        let safeId = id.replacingOccurrences(of: "/", with: "_")
        let fileName = "conversation-\(safeId)-debug-\(Date().timeIntervalSince1970).json"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try jsonData.write(to: fileURL)
        return fileURL
    }
}

// MARK: - XMTPiOS boundary mappers

extension MessagingConversationDebugInfo {
    /// Build a messaging-layer debug-info snapshot from the XMTPiOS
    /// value struct.
    public init(_ xmtpDebugInfo: XMTPiOS.ConversationDebugInfo) {
        self.init(
            epoch: xmtpDebugInfo.epoch,
            maybeForked: xmtpDebugInfo.maybeForked,
            forkDetails: xmtpDebugInfo.forkDetails,
            localCommitLog: xmtpDebugInfo.localCommitLog,
            remoteCommitLog: xmtpDebugInfo.remoteCommitLog,
            commitLogForkStatus: MessagingCommitLogForkStatus(xmtpDebugInfo.commitLogForkStatus)
        )
    }
}

extension MessagingCommitLogForkStatus {
    public init(_ xmtpStatus: XMTPiOS.CommitLogForkStatus) {
        switch xmtpStatus {
        case .forked: self = .forked
        case .notForked: self = .notForked
        case .unknown: self = .unknown
        }
    }
}
