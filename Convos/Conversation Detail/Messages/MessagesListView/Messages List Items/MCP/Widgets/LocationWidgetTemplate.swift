import Foundation

enum LocationWidgetTemplate {
    static func render(data: [String: Any]) -> String {
        let latitude = data["latitude"] as? Double ?? 0
        let longitude = data["longitude"] as? Double ?? 0
        let name = data["name"] as? String ?? "Location"
        let address = data["address"] as? String

        let mapsURL = "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(urlEncode(name))"

        var addressHTML = ""
        if let address {
            addressHTML = """
            <div class="location-address">\(sanitize(address))</div>
            """
        }

        return """
        <div class="location-widget">
            <div class="location-icon">
                <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
                    <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7z"
                          fill="currentColor" opacity="0.8"/>
                    <circle cx="12" cy="9" r="2.5" fill="var(--mcp-color-background)"/>
                </svg>
            </div>
            <div class="location-name">\(sanitize(name))</div>
            \(addressHTML)
            <a class="location-link" href="\(mapsURL)">Open in Maps</a>
        </div>
        <style>
            .location-widget {
                text-align: center;
                padding: 12px 8px;
            }
            .location-icon {
                color: var(--mcp-color-primary);
                margin-bottom: 8px;
            }
            .location-name {
                font-size: 16px;
                font-weight: 600;
                color: var(--mcp-color-text);
            }
            .location-address {
                font-size: 13px;
                color: var(--mcp-color-secondary);
                margin-top: 4px;
                line-height: 1.3;
            }
            .location-link {
                display: inline-block;
                margin-top: 12px;
                font-size: 14px;
                color: var(--mcp-color-primary);
                text-decoration: none;
                padding: 6px 16px;
                border: 1px solid var(--mcp-color-border);
                border-radius: 8px;
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

    private static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }
}
