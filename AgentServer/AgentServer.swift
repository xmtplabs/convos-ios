import Foundation
import Network
import XCTest

// MARK: - Models

struct ScreenState: Codable {
    let elements: [UIElementInfo]
    let focusedElement: UIElementInfo?
    let alerts: [UIElementInfo]
    let navigationBars: [String]
    let timestamp: TimeInterval
}

struct UIElementInfo: Codable {
    let identifier: String?
    let label: String?
    let value: String?
    let placeholderValue: String?
    let elementType: String
    let frame: FrameInfo
    let isEnabled: Bool
    let isHittable: Bool
    let isSelected: Bool
    let hasFocus: Bool
    let children: [UIElementInfo]?
    let customActions: [String]?
}

struct FrameInfo: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AgentRequest: Codable {
    let action: String
    let params: [String: AnyCodable]?
    let steps: [AgentRequest]?
    let observe: Bool?
}

struct AgentResponse: Codable {
    var success: Bool
    var message: String?
    var screenState: ScreenState?
    var tappedElement: UIElementInfo?
    var error: String?
    var durationMs: Int?
}

// MARK: - AnyCodable for flexible params

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map(\.value)
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as String: try container.encode(v)
        default: try container.encodeNil()
        }
    }

    var stringValue: String? { value as? String }
    var doubleValue: Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
    var intValue: Int? { value as? Int }
    var boolValue: Bool? { value as? Bool }
}

// MARK: - Element Query Matching

enum ElementMatch {
    static func find(
        in app: XCUIApplication,
        identifier: String?,
        label: String?,
        labelContains: String?,
        elementType: String?
    ) -> XCUIElement? {
        // Use direct identifier lookup (fastest path - no full tree traversal)
        if let id = identifier {
            let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if el.waitForExistence(timeout: 0) { return el }
        }

        if let exactLabel = label {
            let predicate = NSPredicate(format: "label == %@", exactLabel)
            let el = app.descendants(matching: .any).matching(predicate).firstMatch
            if el.waitForExistence(timeout: 0) { return el }
        }

        if let partial = labelContains {
            let predicate = NSPredicate(format: "label CONTAINS %@", partial)
            let el = app.descendants(matching: .any).matching(predicate).firstMatch
            if el.waitForExistence(timeout: 0) { return el }
        }

        // Fallback: try identifier as label
        if let id = identifier {
            let predicate = NSPredicate(format: "label == %@", id)
            let el = app.descendants(matching: .any).matching(predicate).firstMatch
            if el.waitForExistence(timeout: 0) { return el }
        }

        return nil
    }

    static func findTextField(
        in app: XCUIApplication,
        identifier: String?,
        label: String?
    ) -> XCUIElement? {
        for type: XCUIElement.ElementType in [.textField, .secureTextField, .textView, .searchField] {
            if let id = identifier {
                let el = app.descendants(matching: type).matching(identifier: id).firstMatch
                if el.exists { return el }
            }
            if let lbl = label {
                let predicate = NSPredicate(format: "label == %@ OR placeholderValue == %@", lbl, lbl)
                let el = app.descendants(matching: type).matching(predicate).firstMatch
                if el.exists { return el }
            }
        }
        return nil
    }
}

// MARK: - Element Info Builder

enum ElementInfoBuilder {
    static func build(from element: XCUIElement, depth: Int = 0, maxDepth: Int = 3) -> UIElementInfo {
        let frame = element.frame
        var children: [UIElementInfo]?

        if depth < maxDepth {
            let childElements = element.children(matching: .any)
            if childElements.count > 0 && childElements.count < 50 { // swiftlint:disable:this empty_count
                children = (0..<childElements.count).compactMap { i in
                    let child = childElements.element(boundBy: i)
                    guard child.exists else { return nil }
                    return build(from: child, depth: depth + 1, maxDepth: maxDepth)
                }
            }
        }

        return UIElementInfo(
            identifier: element.identifier.isEmpty ? nil : element.identifier,
            label: element.label.isEmpty ? nil : element.label,
            value: (element.value as? String)?.isEmpty == false ? element.value as? String : nil,
            placeholderValue: element.placeholderValue?.isEmpty == false ? element.placeholderValue : nil,
            elementType: elementTypeName(element.elementType),
            frame: FrameInfo(
                x: Double(frame.origin.x),
                y: Double(frame.origin.y),
                width: Double(frame.size.width),
                height: Double(frame.size.height)
            ),
            isEnabled: element.isEnabled,
            isHittable: element.isHittable,
            isSelected: element.isSelected,
            hasFocus: element.hasFocus,
            children: children,
            customActions: nil
        )
    }

    static func buildFlat(from app: XCUIApplication) -> [UIElementInfo] {
        var results: [UIElementInfo] = []
        let interactiveTypes: [(XCUIElement.ElementType, Int)] = [
            (.button, 30),
            (.textField, 10), (.secureTextField, 5), (.textView, 5), (.searchField, 5),
            (.switch, 10), (.toggle, 10), (.slider, 5), (.popUpButton, 10),
            (.menuItem, 15), (.link, 10), (.alert, 5), (.sheet, 5), (.toolbar, 5),
            (.staticText, 15),
        ]

        for (type, maxCount) in interactiveTypes {
            let t0 = CFAbsoluteTimeGetCurrent()
            let query = app.descendants(matching: type)
            let count = query.count // swiftlint:disable:this empty_count
            let limit = min(count, maxCount)
            for i in 0..<limit {
                let el = query.element(boundBy: i)
                // Guard against stale snapshots — element may vanish mid-iteration
                guard el.waitForExistence(timeout: 0) else { continue }
                let id = el.identifier
                let label = el.label
                if id.isEmpty && label.isEmpty { continue }

                results.append(UIElementInfo(
                    identifier: id.isEmpty ? nil : id,
                    label: label.isEmpty ? nil : label,
                    value: nil,
                    placeholderValue: nil,
                    elementType: elementTypeName(type),
                    frame: FrameInfo(x: 0, y: 0, width: 0, height: 0),
                    isEnabled: true,
                    isHittable: true,
                    isSelected: false,
                    hasFocus: false,
                    children: nil,
                    customActions: nil
                ))
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            if count > 0 {
                print("[TEST PERF] query \(elementTypeName(type)): \(limit)/\(count) in \(Int((t1 - t0) * 1000))ms")
            }
        }

        // Also scan springboard for system dialogs, share sheets, etc.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let sbTypes: [(XCUIElement.ElementType, Int)] = [
            (.button, 15), (.staticText, 10), (.textField, 5), (.alert, 5),
        ]
        for (type, maxCount) in sbTypes {
            let query = springboard.descendants(matching: type)
            let count = query.count // swiftlint:disable:this empty_count
            let limit = min(count, maxCount)
            for i in 0..<limit {
                let el = query.element(boundBy: i)
                guard el.waitForExistence(timeout: 0) else { continue }
                let id = el.identifier
                let label = el.label
                if id.isEmpty && label.isEmpty { continue }
                results.append(UIElementInfo(
                    identifier: id.isEmpty ? nil : id,
                    label: label.isEmpty ? nil : label,
                    value: nil,
                    placeholderValue: nil,
                    elementType: "springboard.\(elementTypeName(type))",
                    frame: FrameInfo(x: 0, y: 0, width: 0, height: 0),
                    isEnabled: true,
                    isHittable: true,
                    isSelected: false,
                    hasFocus: false,
                    children: nil,
                    customActions: nil
                ))
            }
        }

        return results
    }

    static func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .staticText: return "staticText"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .textView: return "textView"
        case .image: return "image"
        case .cell: return "cell"
        case .table: return "table"
        case .collectionView: return "collectionView"
        case .scrollView: return "scrollView"
        case .navigationBar: return "navigationBar"
        case .tabBar: return "tabBar"
        case .toolbar: return "toolbar"
        case .switch: return "switch"
        case .slider: return "slider"
        case .alert: return "alert"
        case .sheet: return "sheet"
        case .popUpButton: return "popUpButton"
        case .menuButton: return "menuButton"
        case .menu: return "menu"
        case .menuItem: return "menuItem"
        case .link: return "link"
        case .toggle: return "toggle"
        case .searchField: return "searchField"
        case .window: return "window"
        case .group: return "group"
        case .other: return "other"
        case .application: return "application"
        default: return "unknown"
        }
    }
}

// MARK: - Screen State Builder

enum ScreenStateBuilder {
    static func capture(app: XCUIApplication) -> ScreenState {
        let elements = ElementInfoBuilder.buildFlat(from: app)

        var alerts = app.alerts.allElementsBoundByIndex.filter(\.exists).map {
            ElementInfoBuilder.build(from: $0, depth: 0, maxDepth: 2)
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAlerts = springboard.alerts.allElementsBoundByIndex.filter(\.exists).map {
            ElementInfoBuilder.build(from: $0, depth: 0, maxDepth: 2)
        }
        alerts.append(contentsOf: springboardAlerts)

        let navBars = app.navigationBars.allElementsBoundByIndex.compactMap { bar -> String? in
            guard bar.exists else { return nil }
            return bar.identifier.isEmpty ? bar.label : bar.identifier
        }

        let focused = elements.first(where: \.hasFocus)

        return ScreenState(
            elements: elements,
            focusedElement: focused,
            alerts: alerts,
            navigationBars: navBars,
            timestamp: Date().timeIntervalSince1970
        )
    }
}

// MARK: - Command Handler

class CommandHandler {
    let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    private var shouldObserve: Bool = false

    func handle(_ request: AgentRequest) -> AgentResponse {
        shouldObserve = request.observe ?? false
        defer { shouldObserve = false }
        let start = CFAbsoluteTimeGetCurrent()
        var result = dispatch(request)
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        result.durationMs = elapsed
        print("[TEST PERF] \(request.action): \(elapsed)ms")
        return result
    }

    private func dispatch(_ request: AgentRequest) -> AgentResponse {
        switch request.action {
        case "observeScreen":
            return observeScreen()
        case "tapElement":
            return tapElement(request.params)
        case "fillField":
            return fillField(request.params)
        case "tapCoordinate":
            return tapCoordinate(request.params)
        case "swipe":
            return swipe(request.params)
        case "scrollUntilVisible":
            return scrollUntilVisible(request.params)
        case "waitForElement":
            return waitForElement(request.params)
        case "pressKey":
            return pressKey(request.params)
        case "longPress":
            return longPress(request.params)
        case "doubleTap":
            return doubleTap(request.params)
        case "chain":
            // steps can come from top-level or from params.steps
            var chainSteps = request.steps
            if chainSteps == nil || chainSteps?.isEmpty == true {
                if let paramsSteps = request.params?["steps"],
                   let encoded = try? JSONEncoder().encode(paramsSteps),
                   let decoded = try? JSONDecoder().decode([AgentRequest].self, from: encoded) {
                    chainSteps = decoded
                }
            }
            return chain(chainSteps)
        case "ping":
            return AgentResponse(success: true, message: "pong", screenState: nil, tappedElement: nil, error: nil)
        default:
            return AgentResponse(
                success: false, message: nil, screenState: nil, tappedElement: nil,
                error: "Unknown action: \(request.action)"
            )
        }
    }

    var skipSettleAndCapture: Bool = false

    private func chain(_ steps: [AgentRequest]?) -> AgentResponse {
        guard let steps, !steps.isEmpty else {
            return errorResponse("chain requires non-empty steps array")
        }

        var messages: [String] = []
        for (i, step) in steps.enumerated() {
            let isLast = i == steps.count - 1
            skipSettleAndCapture = !isLast
            let result = handle(step)
            skipSettleAndCapture = false
            if !result.success {
                let state = ScreenStateBuilder.capture(app: app)
                return AgentResponse(
                    success: false,
                    message: "Failed at step \(i + 1)/\(steps.count): \(step.action)",
                    screenState: state,
                    tappedElement: nil,
                    error: result.error
                )
            }
            if let msg = result.message {
                messages.append("[\(i + 1)] \(step.action): \(msg)")
            }
        }

        let state = captureIfNeeded()
        return AgentResponse(
            success: true,
            message: messages.joined(separator: "\n"),
            screenState: state,
            tappedElement: nil,
            error: nil
        )
    }

    // MARK: - Actions

    private func observeScreen() -> AgentResponse {
        let state = ScreenStateBuilder.capture(app: app)
        return AgentResponse(success: true, message: nil, screenState: state, tappedElement: nil, error: nil)
    }

    private func tapElement(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params else {
            return errorResponse("tapElement requires params")
        }

        let identifier = params["identifier"]?.stringValue
        let label = params["label"]?.stringValue
        let labelContains = params["labelContains"]?.stringValue
        let timeout = params["timeout"]?.doubleValue ?? 5.0

        guard identifier != nil || label != nil || labelContains != nil else {
            return errorResponse("tapElement requires identifier, label, or labelContains")
        }

        var t0 = CFAbsoluteTimeGetCurrent()
        guard let element = waitAndFind(
            identifier: identifier, label: label, labelContains: labelContains,
            timeout: timeout
        ) else {
            let state = shouldObserve ? ScreenStateBuilder.capture(app: app) : nil
            return AgentResponse(
                success: false, message: nil, screenState: state, tappedElement: nil,
                error: "Element not found within \(timeout)s"
            )
        }
        var t1 = CFAbsoluteTimeGetCurrent()
        print("[TEST PERF] waitAndFind: \(Int((t1 - t0) * 1000))ms")

        t0 = CFAbsoluteTimeGetCurrent()
        let elId = element.identifier
        let elLabel = element.label
        t1 = CFAbsoluteTimeGetCurrent()
        print("[TEST PERF] read id+label: \(Int((t1 - t0) * 1000))ms")

        t0 = CFAbsoluteTimeGetCurrent()
        element.tap()
        t1 = CFAbsoluteTimeGetCurrent()
        print("[TEST PERF] tap: \(Int((t1 - t0) * 1000))ms")

        t0 = CFAbsoluteTimeGetCurrent()
        waitForSettle()
        t1 = CFAbsoluteTimeGetCurrent()
        print("[TEST PERF] settle: \(Int((t1 - t0) * 1000))ms")

        t0 = CFAbsoluteTimeGetCurrent()
        let state = captureIfNeeded()
        t1 = CFAbsoluteTimeGetCurrent()
        print("[TEST PERF] capture: \(Int((t1 - t0) * 1000))ms")
        let info = UIElementInfo(
            identifier: elId.isEmpty ? nil : elId,
            label: elLabel.isEmpty ? nil : elLabel,
            value: nil, placeholderValue: nil,
            elementType: "element",
            frame: FrameInfo(x: 0, y: 0, width: 0, height: 0),
            isEnabled: true, isHittable: true, isSelected: false, hasFocus: false,
            children: nil, customActions: nil
        )
        return AgentResponse(success: true, message: "Tapped", screenState: state, tappedElement: info, error: nil)
    }

    private func fillField(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params else {
            return errorResponse("fillField requires params")
        }

        let identifier = params["identifier"]?.stringValue
        let label = params["label"]?.stringValue
        let text = params["text"]?.stringValue ?? ""
        let clearFirst = params["clearFirst"]?.boolValue ?? false
        let timeout = params["timeout"]?.doubleValue ?? 5.0

        guard let element = waitAndFindTextField(
            identifier: identifier, label: label, timeout: timeout
        ) else {
            let state = ScreenStateBuilder.capture(app: app)
            return AgentResponse(
                success: false, message: nil, screenState: state, tappedElement: nil,
                error: "Text field not found within \(timeout)s"
            )
        }

        element.tap()

        if clearFirst {
            element.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 1.0) {
                selectAll.tap()
            }
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 1))
        }

        element.typeText(text)
        waitForSettle()
        let state = captureIfNeeded()
        return AgentResponse(success: true, message: "Typed '\(text)'", screenState: state, tappedElement: nil, error: nil)
    }

    private func tapCoordinate(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params,
              let x = params["x"]?.doubleValue,
              let y = params["y"]?.doubleValue else {
            return errorResponse("tapCoordinate requires x and y")
        }

        let duration = params["duration"]?.doubleValue ?? 0

        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: x, dy: y))

        if duration > 0 {
            coordinate.press(forDuration: duration)
        } else {
            coordinate.tap()
        }

        waitForSettle()
        let state = captureIfNeeded()
        return AgentResponse(success: true, message: "Tapped (\(x), \(y))", screenState: state, tappedElement: nil, error: nil)
    }

    private func swipe(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params,
              let direction = params["direction"]?.stringValue else {
            return errorResponse("swipe requires direction (up/down/left/right)")
        }

        let identifier = params["identifier"]?.stringValue
        let target: XCUIElement

        if let id = identifier,
           let found = ElementMatch.find(in: app, identifier: id, label: nil, labelContains: nil, elementType: nil) {
            target = found
        } else {
            target = app
        }

        switch direction {
        case "up": target.swipeUp()
        case "down": target.swipeDown()
        case "left": target.swipeLeft()
        case "right": target.swipeRight()
        default:
            return errorResponse("Invalid direction: \(direction)")
        }

        waitForSettle()
        let state = captureIfNeeded()
        return AgentResponse(success: true, message: "Swiped \(direction)", screenState: state, tappedElement: nil, error: nil)
    }

    private func scrollUntilVisible(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params else {
            return errorResponse("scrollUntilVisible requires params")
        }

        let identifier = params["identifier"]?.stringValue
        let label = params["label"]?.stringValue
        let labelContains = params["labelContains"]?.stringValue
        let direction = params["direction"]?.stringValue ?? "up"
        let maxSwipes = params["maxSwipes"]?.intValue ?? 10

        for _ in 0..<maxSwipes {
            if let el = ElementMatch.find(
                in: app, identifier: identifier, label: label,
                labelContains: labelContains, elementType: nil
            ), el.isHittable {
                let info = ElementInfoBuilder.build(from: el, depth: 0, maxDepth: 0)
                let state = captureIfNeeded()
                return AgentResponse(success: true, message: "Found after scrolling", screenState: state, tappedElement: info, error: nil)
            }

            switch direction {
            case "up": app.swipeUp()
            case "down": app.swipeDown()
            default: app.swipeUp()
            }

            waitForSettle()
        }

        let state = ScreenStateBuilder.capture(app: app)
        return AgentResponse(
            success: false, message: nil, screenState: state, tappedElement: nil,
            error: "Element not found after \(maxSwipes) swipes"
        )
    }

    private func waitForElement(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params else {
            return errorResponse("waitForElement requires params")
        }

        let identifier = params["identifier"]?.stringValue
        let label = params["label"]?.stringValue
        let labelContains = params["labelContains"]?.stringValue
        let timeout = params["timeout"]?.doubleValue ?? 5.0

        guard let element = waitAndFind(
            identifier: identifier, label: label, labelContains: labelContains,
            timeout: timeout
        ) else {
            let state = ScreenStateBuilder.capture(app: app)
            return AgentResponse(
                success: false, message: nil, screenState: state, tappedElement: nil,
                error: "Element not found within \(timeout)s"
            )
        }

        let info = ElementInfoBuilder.build(from: element, depth: 0, maxDepth: 0)
        let state = captureIfNeeded()
        return AgentResponse(success: true, message: "Found", screenState: state, tappedElement: info, error: nil)
    }

    private func pressKey(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params,
              let key = params["key"]?.stringValue else {
            return errorResponse("pressKey requires key")
        }

        switch key {
        case "return", "enter":
            app.typeText("\n")
        case "delete", "backspace":
            app.typeText(XCUIKeyboardKey.delete.rawValue)
        case "escape":
            app.typeText(XCUIKeyboardKey.escape.rawValue)
        case "tab":
            app.typeText("\t")
        default:
            app.typeText(key)
        }

        waitForSettle()
        let state = captureIfNeeded()
        return AgentResponse(success: true, message: "Pressed \(key)", screenState: state, tappedElement: nil, error: nil)
    }

    private func longPress(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params else {
            return errorResponse("longPress requires params")
        }

        let identifier = params["identifier"]?.stringValue
        let label = params["label"]?.stringValue
        let labelContains = params["labelContains"]?.stringValue
        let duration = params["duration"]?.doubleValue ?? 1.0
        let timeout = params["timeout"]?.doubleValue ?? 5.0

        guard let element = waitAndFind(
            identifier: identifier, label: label, labelContains: labelContains,
            timeout: timeout
        ) else {
            let state = ScreenStateBuilder.capture(app: app)
            return AgentResponse(
                success: false, message: nil, screenState: state, tappedElement: nil,
                error: "Element not found within \(timeout)s"
            )
        }

        let info = ElementInfoBuilder.build(from: element, depth: 0, maxDepth: 0)
        element.press(forDuration: duration)
        waitForSettle()
        let state = captureIfNeeded()
        return AgentResponse(success: true, message: "Long pressed for \(duration)s", screenState: state, tappedElement: info, error: nil)
    }

    private func doubleTap(_ params: [String: AnyCodable]?) -> AgentResponse {
        guard let params else {
            return errorResponse("doubleTap requires params")
        }

        let identifier = params["identifier"]?.stringValue
        let label = params["label"]?.stringValue
        let labelContains = params["labelContains"]?.stringValue
        let timeout = params["timeout"]?.doubleValue ?? 5.0

        guard let element = waitAndFind(
            identifier: identifier, label: label, labelContains: labelContains,
            timeout: timeout
        ) else {
            let state = ScreenStateBuilder.capture(app: app)
            return AgentResponse(
                success: false, message: nil, screenState: state, tappedElement: nil,
                error: "Element not found within \(timeout)s"
            )
        }

        let info = ElementInfoBuilder.build(from: element, depth: 0, maxDepth: 0)
        element.doubleTap()
        waitForSettle()
        let state = captureIfNeeded()
        return AgentResponse(success: true, message: "Double tapped", screenState: state, tappedElement: info, error: nil)
    }

    // MARK: - Helpers

    private let springboard: XCUIApplication = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func waitAndFind(
        identifier: String?,
        label: String?,
        labelContains: String?,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let el = ElementMatch.find(
                in: app, identifier: identifier, label: label,
                labelContains: labelContains, elementType: nil
            ) {
                return el
            }
            // Check springboard every iteration (for share sheets, system dialogs)
            if let el = ElementMatch.find(
                in: springboard, identifier: identifier, label: label,
                labelContains: labelContains, elementType: nil
            ) {
                return el
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return nil
    }

    private func waitAndFindTextField(
        identifier: String?,
        label: String?,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let el = ElementMatch.findTextField(in: app, identifier: identifier, label: label) {
                return el
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return nil
    }

    private func waitForSettle() {
        guard !skipSettleAndCapture else { return }
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func captureIfNeeded() -> ScreenState? {
        guard !skipSettleAndCapture && shouldObserve else { return nil }
        return ScreenStateBuilder.capture(app: app)
    }

    private func errorResponse(_ message: String) -> AgentResponse {
        AgentResponse(success: false, message: nil, screenState: nil, tappedElement: nil, error: message)
    }
}

// MARK: - HTTP Server using Network.framework

class AgentHTTPServer {
    let handler: CommandHandler
    let port: UInt16
    private var listener: NWListener?

    init(handler: CommandHandler, port: UInt16 = 8615) {
        self.handler = handler
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "AgentServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }
        listener = try NWListener(using: params, on: nwPort)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.start(queue: .global())
        print("[AgentServer] Listening on port \(port)")
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveHTTPRequest(connection)
    }

    private func receiveHTTPRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, _ in
            guard let self, let data = content else {
                connection.cancel()
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.sendHTTPResponse(connection, statusCode: 400, body: #"{"error":"Invalid request"}"#)
                return
            }

            // Parse HTTP request
            let lines = requestString.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let firstLine = lines.first else {
                self.sendHTTPResponse(connection, statusCode: 400, body: #"{"error":"Empty request"}"#)
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendHTTPResponse(connection, statusCode: 400, body: #"{"error":"Malformed request line"}"#)
                return
            }

            let method = String(parts[0])
            let path = String(parts[1])

            // Find body after double CRLF
            var bodyData: Data?
            if let bodyRange = requestString.range(of: "\r\n\r\n") {
                let bodyString = String(requestString[bodyRange.upperBound...])
                if !bodyString.isEmpty {
                    bodyData = bodyString.data(using: .utf8)
                }
            }

            // Check Content-Length and read more if needed
            var contentLength = 0
            for line in lines where line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }

            let currentBodyLength = bodyData?.count ?? 0
            if contentLength > 0 && currentBodyLength < contentLength {
                // Need to read more data
                let remaining = contentLength - currentBodyLength
                connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] moreData, _, _, _ in
                    guard let self else { return }
                    var fullBody = bodyData ?? Data()
                    if let more = moreData {
                        fullBody.append(more)
                    }
                    self.routeRequest(connection, method: method, path: path, body: fullBody)
                }
                return
            }

            self.routeRequest(connection, method: method, path: path, body: bodyData)
        }
    }

    private func routeRequest(_ connection: NWConnection, method: String, path: String, body: Data?) {
        if method == "GET" && path == "/ping" {
            sendHTTPResponse(connection, statusCode: 200, body: #"{"success":true,"message":"pong"}"#)
            return
        }

        if method == "POST" && path == "/action" {
            guard let body,
                  let request = try? JSONDecoder().decode(AgentRequest.self, from: body) else {
                sendHTTPResponse(connection, statusCode: 400, body: #"{"error":"Invalid JSON body"}"#)
                return
            }

            // Execute on main thread since XCUITest requires it
            var response: AgentResponse?
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                response = self.handler.handle(request)
                semaphore.signal()
            }
            semaphore.wait()

            guard let response else {
                self.sendHTTPResponse(connection, statusCode: 500, body: #"{"error":"No response from handler"}"#)
                return
            }

            if let responseData = try? JSONEncoder().encode(response),
               let responseString = String(data: responseData, encoding: .utf8) {
                sendHTTPResponse(connection, statusCode: 200, body: responseString)
            } else {
                sendHTTPResponse(connection, statusCode: 500, body: #"{"error":"Failed to encode response"}"#)
            }
            return
        }

        sendHTTPResponse(connection, statusCode: 404, body: #"{"error":"Not found"}"#)
    }

    private func sendHTTPResponse(_ connection: NWConnection, statusCode: Int, body: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
