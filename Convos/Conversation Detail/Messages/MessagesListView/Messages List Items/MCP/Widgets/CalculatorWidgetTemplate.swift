import Foundation

enum CalculatorWidgetTemplate {
    static func render(input: [String: Any]?, result: [String: Any]?) -> String {
        let expression = input?["expression"] as? String ?? ""
        let answer = result?["result"]

        let answerText: String
        if let intVal = answer as? Int {
            answerText = "\(intVal)"
        } else if let doubleVal = answer as? Double {
            answerText = doubleVal.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(doubleVal))"
                : String(format: "%.4g", doubleVal)
        } else if let strVal = answer as? String {
            answerText = sanitize(strVal)
        } else {
            answerText = "—"
        }

        let displayExpression = formatExpression(expression)

        return """
        <div class="calc-widget">
            <div class="calc-expression">\(sanitize(displayExpression))</div>
            <div class="calc-divider"></div>
            <div class="calc-answer">\(answerText)</div>
        </div>
        <style>
            .calc-widget {
                padding: 16px 20px;
                text-align: right;
            }
            .calc-expression {
                font-size: 15px;
                color: var(--mcp-color-secondary);
                font-family: 'SF Mono', ui-monospace, monospace;
                letter-spacing: 0.5px;
                word-break: break-all;
            }
            .calc-divider {
                height: 1px;
                background: var(--mcp-color-border);
                margin: 10px 0;
            }
            .calc-answer {
                font-size: 36px;
                font-weight: 300;
                color: var(--mcp-color-primary);
                font-family: 'SF Mono', ui-monospace, monospace;
                line-height: 1.1;
            }
        </style>
        """
    }

    private static func formatExpression(_ expr: String) -> String {
        expr.replacingOccurrences(of: "*", with: " \u{00D7} ")
            .replacingOccurrences(of: "/", with: " \u{00F7} ")
            .replacingOccurrences(of: "+", with: " + ")
            .replacingOccurrences(of: "-", with: " \u{2212} ")
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
