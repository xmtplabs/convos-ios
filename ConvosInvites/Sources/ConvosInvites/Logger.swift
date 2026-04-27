import Foundation
import Logging

/// ConvosInvites logging wrapper - uses "ConvosInvites" namespace and the
/// swift-log `LoggingSystem` configured by the host app.
///
/// Internal so it does not collide with `ConvosCore.Log` for downstream consumers.
enum Log {
    private static let logger: Logging.Logger = Logging.Logger(label: "convos")

    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger.debug("[ConvosInvites] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger.info("[ConvosInvites] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger.warning("[ConvosInvites] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger.error("[ConvosInvites] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    private static func makeSource(file: String, function: String, line: Int) -> String {
        let fileName = (file as NSString).lastPathComponent
        return "\(fileName):\(line) \(function)"
    }
}
