import Foundation

/// The deterministic outcome of tapping "Make" in the Agent Builder: the
/// `AgentBuilderSummary` to persist + render, and the `clientMessageId`s the
/// builder will issue on the user's behalf. Computing this in one place keeps
/// the id-allocation / bundle-detection logic out of the view model and lets
/// the crash-safety contract (`bundledMessageIds` must exactly match the sends
/// the builder issues) be unit-tested without a SwiftUI host.
public struct AgentBuilderCommitPlan: Sendable, Equatable {
    public let summary: AgentBuilderSummary
    /// `clientMessageId` for the prompt-text send, or `nil` when the prompt is
    /// empty (connections / media only).
    public let textMessageId: String?
    /// `clientMessageId` for the multi-remote attachment bundle send, or `nil`
    /// when there is nothing to bundle (no voice memo, photos, videos, files).
    public let bundleMessageId: String?

    public init(summary: AgentBuilderSummary, textMessageId: String?, bundleMessageId: String?) {
        self.summary = summary
        self.textMessageId = textMessageId
        self.bundleMessageId = bundleMessageId
    }
}

public enum AgentBuilderCommitPlanner {
    /// Build the commit plan from the summary attachments the view model has
    /// already assembled (thumbnails encoded iOS-side) plus the prompt and any
    /// captured cloud-connection ids.
    ///
    /// The prompt is trimmed of whitespace and newlines; a blank prompt is
    /// treated as no prompt (no text id, empty summary prompt) so the builder
    /// never issues a whitespace-only text send. The trimmed value is the
    /// canonical prompt — callers should send `plan.summary.prompt`, not the
    /// raw composer text, so the sent message matches the rendered summary.
    ///
    /// `generateMessageId` and `now` are injectable so the id-allocation and
    /// `cutoffDate` behavior can be asserted deterministically in tests.
    /// `bundleMessageId` is allocated when any non-connection attachment is
    /// present. Note this gate keys off attachment *presence*, while the actual
    /// send (`sendBuilderBundle`) drops photos/videos that never got an eager
    /// upload key — so a `bundleMessageId` can occasionally be allocated for a
    /// bundle that sends nothing. That over-allocation is benign: a
    /// `bundledMessageIds` entry with no matching send just filters nothing.
    public static func makePlan(
        prompt: String,
        attachments: [AgentBuilderSummaryAttachment],
        cloudConnectionIds: [String: String],
        now: Date = Date(),
        generateMessageId: () -> String = { UUID().uuidString }
    ) -> AgentBuilderCommitPlan {
        let trimmedPrompt: String = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let textMessageId: String? = trimmedPrompt.isEmpty ? nil : generateMessageId()
        let willSendBundle: Bool = attachments.contains { attachment in
            switch attachment {
            case .connection:
                return false
            case .photo, .video, .file, .voiceMemo:
                return true
            }
        }
        let bundleMessageId: String? = willSendBundle ? generateMessageId() : nil

        var bundledMessageIds: Set<String> = []
        if let textMessageId {
            bundledMessageIds.insert(textMessageId)
        }
        if let bundleMessageId {
            bundledMessageIds.insert(bundleMessageId)
        }

        // `cutoffDate` gates agent-side pre-Make chatter by timestamp (we don't
        // control the agent's send timing). User-side sends are filtered by id
        // via `bundledMessageIds`, which doesn't suffer the upload-stretch race.
        let summary = AgentBuilderSummary(
            prompt: trimmedPrompt,
            attachments: attachments,
            cutoffDate: now,
            bundledMessageIds: bundledMessageIds,
            cloudConnectionIds: cloudConnectionIds
        )
        return AgentBuilderCommitPlan(
            summary: summary,
            textMessageId: textMessageId,
            bundleMessageId: bundleMessageId
        )
    }
}
