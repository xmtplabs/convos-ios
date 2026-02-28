import Foundation

enum PollWidgetTemplate {
    static func render(input: [String: Any]?, result: [String: Any]?) -> String {
        let question = input?["question"] as? String ?? "Poll"
        let options = input?["options"] as? [String] ?? []
        let votes = result?["votes"] as? [String: Any] ?? [:]
        let totalVotes = result?["totalVotes"] as? Int ?? 0
        let userVote = result?["userVote"] as? String

        var optionsHTML = ""
        for option in options {
            let count = (votes[option] as? Int) ?? 0
            let percentage = totalVotes > 0 ? Int(Double(count) / Double(totalVotes) * 100) : 0
            let isUserVote = option == userVote

            optionsHTML += """
            <div class="poll-option\(isUserVote ? " user-vote" : "")">
                <div class="poll-option-header">
                    <span class="poll-option-label">\(sanitize(option))\(isUserVote ? " &#10003;" : "")</span>
                    <span class="poll-option-count">\(count)</span>
                </div>
                <div class="poll-bar-bg">
                    <div class="poll-bar-fill" style="width: \(percentage)%"></div>
                </div>
                <div class="poll-percentage">\(percentage)%</div>
            </div>
            """
        }

        return """
        <div class="poll-widget">
            <div class="poll-question">\(sanitize(question))</div>
            <div class="poll-options">\(optionsHTML)</div>
            <div class="poll-footer">\(totalVotes) vote\(totalVotes == 1 ? "" : "s")</div>
        </div>
        <style>
            .poll-widget {
                padding: 12px 8px;
            }
            .poll-question {
                font-size: 16px;
                font-weight: 600;
                color: var(--mcp-color-text);
                margin-bottom: 12px;
            }
            .poll-options {
                display: flex;
                flex-direction: column;
                gap: 10px;
            }
            .poll-option-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 4px;
            }
            .poll-option-label {
                font-size: 14px;
                color: var(--mcp-color-text);
            }
            .poll-option-count {
                font-size: 12px;
                color: var(--mcp-color-secondary);
            }
            .poll-bar-bg {
                height: 8px;
                background: var(--mcp-color-border);
                border-radius: 4px;
                overflow: hidden;
            }
            .poll-bar-fill {
                height: 100%;
                background: var(--mcp-color-primary);
                border-radius: 4px;
                transition: width 0.3s ease;
                opacity: 0.6;
            }
            .user-vote .poll-bar-fill {
                opacity: 1;
            }
            .user-vote .poll-option-label {
                font-weight: 600;
            }
            .poll-percentage {
                font-size: 11px;
                color: var(--mcp-color-secondary);
                margin-top: 2px;
            }
            .poll-footer {
                font-size: 12px;
                color: var(--mcp-color-secondary);
                margin-top: 12px;
                text-align: center;
            }
        </style>
        """
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
