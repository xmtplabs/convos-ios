import ConvosCore
import Foundation

/// Share-extension logging wrapper - writes to the shared "convos.log" sink
/// under the app-group container so spike output can be grepped off-device.
enum Log {
    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.debug(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.info(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.warning(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.error(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }
}
