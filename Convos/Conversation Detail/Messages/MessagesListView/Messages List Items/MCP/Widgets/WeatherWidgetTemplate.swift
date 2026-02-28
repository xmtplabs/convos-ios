import Foundation

enum WeatherWidgetTemplate {
    static func render(data: [String: Any]) -> String {
        let temp = data["temp"] as? Int ?? 0
        let condition = data["condition"] as? String ?? "Unknown"
        let location = data["location"] as? String ?? ""
        let high = data["high"] as? Int ?? 0
        let low = data["low"] as? Int ?? 0
        let humidity = data["humidity"] as? Int
        let wind = data["wind"] as? String

        let emoji = conditionEmoji(condition)

        var detailsHTML = ""
        if let humidity {
            detailsHTML += "<span>\(humidity)% humidity</span>"
        }
        if let wind {
            detailsHTML += "<span>\(sanitize(wind)) wind</span>"
        }

        return """
        <div class="weather-widget">
            <div class="weather-main">
                <div class="weather-emoji">\(emoji)</div>
                <div class="weather-temp">\(temp)&deg;</div>
            </div>
            <div class="weather-condition">\(sanitize(condition))</div>
            <div class="weather-location">\(sanitize(location))</div>
            <div class="weather-range">H:\(high)&deg; L:\(low)&deg;</div>
            <div class="weather-details">\(detailsHTML)</div>
        </div>
        <style>
            .weather-widget {
                text-align: center;
                padding: 12px 8px;
            }
            .weather-main {
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
            }
            .weather-emoji {
                font-size: 40px;
                line-height: 1;
            }
            .weather-temp {
                font-size: 48px;
                font-weight: 200;
                line-height: 1;
                color: var(--mcp-color-primary);
            }
            .weather-condition {
                font-size: 16px;
                font-weight: 500;
                margin-top: 4px;
                color: var(--mcp-color-text);
            }
            .weather-location {
                font-size: 13px;
                color: var(--mcp-color-secondary);
                margin-top: 2px;
            }
            .weather-range {
                font-size: 14px;
                color: var(--mcp-color-text);
                margin-top: 8px;
                font-weight: 500;
            }
            .weather-details {
                display: flex;
                justify-content: center;
                gap: 12px;
                margin-top: 4px;
                font-size: 12px;
                color: var(--mcp-color-secondary);
            }
        </style>
        """
    }

    private static func conditionEmoji(_ condition: String) -> String {
        switch condition.lowercased() {
        case let c where c.contains("sun") || c.contains("clear"):
            return "&#9728;&#65039;"
        case let c where c.contains("cloud") && c.contains("part"):
            return "&#9925;"
        case let c where c.contains("cloud") || c.contains("overcast"):
            return "&#9729;&#65039;"
        case let c where c.contains("rain") || c.contains("drizzle"):
            return "&#127783;&#65039;"
        case let c where c.contains("thunder") || c.contains("storm"):
            return "&#9928;&#65039;"
        case let c where c.contains("snow"):
            return "&#127784;&#65039;"
        case let c where c.contains("fog") || c.contains("mist") || c.contains("haze"):
            return "&#127787;&#65039;"
        case let c where c.contains("wind"):
            return "&#127788;&#65039;"
        default:
            return "&#127780;&#65039;"
        }
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
