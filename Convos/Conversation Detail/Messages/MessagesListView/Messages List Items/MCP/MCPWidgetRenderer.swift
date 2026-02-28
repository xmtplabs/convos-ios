import ConvosCore
import Foundation

enum MCPWidgetRenderer {
    static func render(mcpApp: MCPAppContent) -> String? {
        let uri = mcpApp.resourceURI

        if uri.hasPrefix("ui://weather/") {
            return renderWeather(mcpApp: mcpApp)
        } else if uri.hasPrefix("ui://poll/") {
            return renderPoll(mcpApp: mcpApp)
        } else if uri.hasPrefix("ui://location/") {
            return renderLocation(mcpApp: mcpApp)
        } else if uri.hasPrefix("ui://calculator/") {
            return renderCalculator(mcpApp: mcpApp)
        }

        return nil
    }

    private static func renderWeather(mcpApp: MCPAppContent) -> String? {
        guard let data = parseJSON(mcpApp.toolResult) else { return nil }
        return WeatherWidgetTemplate.render(data: data)
    }

    private static func renderPoll(mcpApp: MCPAppContent) -> String? {
        let input = parseJSON(mcpApp.toolInput)
        let result = parseJSON(mcpApp.toolResult)
        guard input != nil || result != nil else { return nil }
        return PollWidgetTemplate.render(input: input, result: result)
    }

    private static func renderLocation(mcpApp: MCPAppContent) -> String? {
        guard let data = parseJSON(mcpApp.toolResult) else { return nil }
        return LocationWidgetTemplate.render(data: data)
    }

    private static func renderCalculator(mcpApp: MCPAppContent) -> String? {
        let input = parseJSON(mcpApp.toolInput)
        let result = parseJSON(mcpApp.toolResult)
        guard input != nil || result != nil else { return nil }
        return CalculatorWidgetTemplate.render(input: input, result: result)
    }

    private static func parseJSON(_ jsonString: String?) -> [String: Any]? {
        guard let jsonString, let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
