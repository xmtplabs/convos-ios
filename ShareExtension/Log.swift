import ConvosCore
import Foundation
import os

/// Share-extension logging wrapper - writes to the shared "convos.log" sink
/// under the app-group container so spike output can be grepped off-device,
/// and mirrors to the unified log so a jetsam kill (which destroys the file
/// sink's async queue) can't hide the trail from a tethered syslog stream.
enum Log {
    private static let osLog: os.Logger = os.Logger(subsystem: "org.convos.shareext", category: "spike")

    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        osLog.debug("\(message, privacy: .public)")
        ConvosLog.debug(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        osLog.info("\(message, privacy: .public)")
        ConvosLog.info(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        osLog.warning("\(message, privacy: .public)")
        ConvosLog.warning(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        osLog.error("\(message, privacy: .public)")
        ConvosLog.error(message, namespace: "ShareExtension", file: file, function: function, line: line)
    }
}
