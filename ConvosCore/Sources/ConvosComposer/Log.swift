#if canImport(UIKit)
import ConvosCore
import Foundation

/// Composer logging wrapper - mirrors the app's Log wrapper but under the
/// package's own namespace.
enum Log {
    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.debug(message, namespace: "ConvosComposer", file: file, function: function, line: line)
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.info(message, namespace: "ConvosComposer", file: file, function: function, line: line)
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.warning(message, namespace: "ConvosComposer", file: file, function: function, line: line)
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.error(message, namespace: "ConvosComposer", file: file, function: function, line: line)
    }
}
#endif
