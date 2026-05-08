import ConvosMetrics
import Foundation

final class StubMetricsCollector: CollectorDelegate, @unchecked Sendable {
    struct NavigationEvent: Equatable {
        let source: String
        let target: String
    }

    struct PresentEvent: Equatable {
        let source: String
        let target: String
    }

    struct CloseEvent {
        let screen: String
        let durationSecs: Float
    }

    struct SendEvent {
        let name: String
        let properties: [String: Any?]
    }

    struct UserPropertiesEvent {
        let properties: [String: Any?]
    }

    private let lock: NSLock = NSLock()
    private var _navigations: [NavigationEvent] = []
    private var _presentations: [PresentEvent] = []
    private var _closes: [CloseEvent] = []
    private var _identifies: [String] = []
    private var _userProperties: [UserPropertiesEvent] = []
    private var _events: [SendEvent] = []

    var navigations: [NavigationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _navigations
    }

    var presentations: [PresentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _presentations
    }

    var closes: [CloseEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _closes
    }

    var identifies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _identifies
    }

    var userProperties: [UserPropertiesEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _userProperties
    }

    var events: [SendEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func eventNames() -> [String] {
        events.map(\.name)
    }

    func events(named name: String) -> [SendEvent] {
        events.filter { $0.name == name }
    }

    override func navigatedTo(source: String, target: String) {
        lock.lock()
        _navigations.append(NavigationEvent(source: source, target: target))
        lock.unlock()
    }

    override func presented(source: String, target: String) {
        lock.lock()
        _presentations.append(PresentEvent(source: source, target: target))
        lock.unlock()
    }

    override func closed(screen: String, context: ScreenContext) {
        lock.lock()
        _closes.append(CloseEvent(screen: screen, durationSecs: context.durationSecs))
        lock.unlock()
    }

    override func identify(userId: String) {
        lock.lock()
        _identifies.append(userId)
        lock.unlock()
    }

    override func updateUserProperties(properties: [String: Any?]) {
        lock.lock()
        _userProperties.append(UserPropertiesEvent(properties: properties))
        lock.unlock()
    }

    override func sendEvent(name: String, properties: [String: Any?]) {
        lock.lock()
        _events.append(SendEvent(name: name, properties: properties))
        lock.unlock()
    }
}
