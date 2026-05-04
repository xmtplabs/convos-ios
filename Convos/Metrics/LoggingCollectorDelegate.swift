import ConvosCore
import Foundation
import NavigationMetrics

final class LoggingCollectorDelegate: CollectorDelegate {
    override func navigatedTo(source: String, target: String) {
        Log.info("nav: \(source) -> \(target)")
    }

    override func presented(source: String, target: String) {
        Log.info("present: \(source) -> \(target)")
    }

    override func closed(screen: String, context: ScreenContext) {
        Log.info("closed: \(screen) durationSecs=\(context.durationSecs)")
    }
}
