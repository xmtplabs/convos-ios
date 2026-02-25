import Foundation

public enum QAEvent {
    public enum Category: String {
        case message
        case conversation
        case reaction
        case profile
        case sync
        case invite
        case member
        case app
    }

    public static func emit(
        _ category: Category,
        _ action: String,
        _ params: [String: String] = [:],
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let paramString = params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: " ", with: "_"))" }
            .joined(separator: " ")
        let event = paramString.isEmpty
            ? "[EVENT] \(category.rawValue).\(action)"
            : "[EVENT] \(category.rawValue).\(action) \(paramString)"
        ConvosLog.info(event, namespace: "ConvosCore", file: file, function: function, line: line)
    }
}
