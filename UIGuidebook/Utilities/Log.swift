import Foundation
import OSLog

enum Log {
    private static let logger = Logger(subsystem: "org.convos.UIGuidebook", category: "Default")

    static func info(_ message: String) {
        logger.info("\(message)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message)")
    }
}
