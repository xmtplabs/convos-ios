import ConvosCore
import Foundation
import WebKit

protocol MCPAppBridgeDelegate: AnyObject {
    func bridge(_ bridge: MCPAppBridge, didReceiveMessage content: [JSONValue])
    func bridge(_ bridge: MCPAppBridge, didRequestOpenLink url: URL)
    func bridge(_ bridge: MCPAppBridge, didUpdateModelContext content: JSONValue?)
    func bridge(_ bridge: MCPAppBridge, didRequestDisplayMode mode: String)
    func bridge(_ bridge: MCPAppBridge, didReportSize width: CGFloat?, height: CGFloat?)
}

extension MCPAppBridgeDelegate {
    func bridge(_ bridge: MCPAppBridge, didReceiveMessage content: [JSONValue]) {}
    func bridge(_ bridge: MCPAppBridge, didRequestOpenLink url: URL) {}
    func bridge(_ bridge: MCPAppBridge, didUpdateModelContext content: JSONValue?) {}
    func bridge(_ bridge: MCPAppBridge, didRequestDisplayMode mode: String) {}
    func bridge(_ bridge: MCPAppBridge, didReportSize width: CGFloat?, height: CGFloat?) {}
}

@MainActor
final class MCPAppBridge: NSObject, WKScriptMessageHandler {
    weak var delegate: MCPAppBridgeDelegate?

    private weak var webView: WKWebView?
    private let hostContext: MCPAppHostContext
    private let mcpApp: MCPAppContent
    private var isInitialized: Bool = false
    private var pendingToolInput: [String: Any]?
    private var pendingToolResult: JSONValue?

    init(mcpApp: MCPAppContent, hostContext: MCPAppHostContext) {
        self.mcpApp = mcpApp
        self.hostContext = hostContext
        super.init()
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        webView.configuration.userContentController.add(self, name: Constant.messageHandler)

        let bridgeScript = WKUserScript(
            source: Self.bridgeInjectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(bridgeScript)
    }

    func detach() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Constant.messageHandler)
        webView = nil
    }

    func sendToolInput(_ arguments: [String: Any]) {
        guard isInitialized else {
            pendingToolInput = arguments
            return
        }
        sendNotification(method: .toolInput, params: .object(["arguments": JSONValue.from(arguments)]))
    }

    func sendToolResult(_ result: JSONValue) {
        guard isInitialized else {
            pendingToolResult = result
            return
        }
        sendNotification(method: .toolResult, params: result)
    }

    func sendToolCancelled(reason: String? = nil) {
        var params: [String: JSONValue] = [:]
        if let reason {
            params["reason"] = .string(reason)
        }
        sendNotification(method: .toolCancelled, params: .object(params))
    }

    func sendHostContextChanged(_ context: MCPAppHostContext) {
        guard let data = try? JSONEncoder().encode(context),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        sendNotification(method: .hostContextChanged, params: JSONValue.from(jsonObject))
    }

    func sendResourceTeardown() {
        sendRequest(method: .resourceTeardown, params: .object([:]))
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Constant.messageHandler,
              let body = message.body as? [String: Any],
              let method = body["method"] as? String else { return }

        let id = body["id"] as? Int
        let params = body["params"] as? [String: Any]

        handleMessage(method: method, id: id, params: params)
    }

    // MARK: - Message Handling

    private func handleMessage(method: String, id: Int?, params: [String: Any]?) {
        guard let mcpMethod = MCPAppProtocol.Method(rawValue: method) else {
            if let id {
                sendErrorResponse(id: id, error: .methodNotFound)
            }
            return
        }

        switch mcpMethod {
        case .initialize:
            handleInitialize(id: id, params: params)
        case .initialized:
            handleInitialized()
        case .message:
            handleUIMessage(id: id, params: params)
        case .openLink:
            handleOpenLink(id: id, params: params)
        case .updateModelContext:
            handleUpdateModelContext(id: id, params: params)
        case .requestDisplayMode:
            handleRequestDisplayMode(id: id, params: params)
        case .sizeChanged:
            handleSizeChanged(params: params)
        case .ping:
            if let id {
                sendSuccessResponse(id: id, result: .object([:]))
            }
        default:
            if let id {
                sendErrorResponse(id: id, error: .methodNotFound)
            }
        }
    }

    private func handleInitialize(id: Int?, params: [String: Any]?) {
        guard let id else { return }

        let initResult = MCPAppInitializeResult(
            hostInfo: .init(name: Constant.hostName, version: Constant.hostVersion),
            hostCapabilities: .object([
                "openLinks": .object([:]),
                "message": .object([:]),
                "updateModelContext": .object([
                    "text": .object([:])
                ])
            ]),
            hostContext: hostContext
        )

        guard let data = try? JSONEncoder().encode(initResult),
              let resultDict = try? JSONSerialization.jsonObject(with: data) else {
            sendErrorResponse(id: id, error: .serverError("Failed to encode init result"))
            return
        }

        sendSuccessResponse(id: id, result: JSONValue.from(resultDict))
    }

    private func handleInitialized() {
        isInitialized = true

        if let pendingToolInput {
            sendToolInput(pendingToolInput)
            self.pendingToolInput = nil
        }

        if let pendingToolResult {
            sendToolResult(pendingToolResult)
            self.pendingToolResult = nil
        }
    }

    private func handleUIMessage(id: Int?, params: [String: Any]?) {
        guard let id, let params, let content = params["content"] else {
            if let id {
                sendErrorResponse(id: id, error: .invalidParams)
            }
            return
        }
        let contentValue = JSONValue.from(content)
        if case .array(let items) = contentValue {
            delegate?.bridge(self, didReceiveMessage: items)
        }
        sendSuccessResponse(id: id, result: .object([:]))
    }

    private func handleOpenLink(id: Int?, params: [String: Any]?) {
        guard let id, let params, let urlString = params["url"] as? String, let url = URL(string: urlString) else {
            if let id {
                sendErrorResponse(id: id, error: .invalidParams)
            }
            return
        }
        guard let scheme = url.scheme, Constant.allowedURLSchemes.contains(scheme) else {
            sendErrorResponse(id: id, error: .serverError("URL scheme not allowed"))
            return
        }
        delegate?.bridge(self, didRequestOpenLink: url)
        sendSuccessResponse(id: id, result: .object([:]))
    }

    private func handleUpdateModelContext(id: Int?, params: [String: Any]?) {
        guard let id else { return }
        let contentValue: JSONValue? = params.map { JSONValue.from($0) }
        delegate?.bridge(self, didUpdateModelContext: contentValue)
        sendSuccessResponse(id: id, result: .object([:]))
    }

    private func handleRequestDisplayMode(id: Int?, params: [String: Any]?) {
        guard let id, let params, let mode = params["mode"] as? String else {
            if let id {
                sendErrorResponse(id: id, error: .invalidParams)
            }
            return
        }
        delegate?.bridge(self, didRequestDisplayMode: mode)
        sendSuccessResponse(id: id, result: .object(["mode": .string("inline")]))
    }

    private func handleSizeChanged(params: [String: Any]?) {
        let width = params?["width"] as? CGFloat
        let height = params?["height"] as? CGFloat
        delegate?.bridge(self, didReportSize: width, height: height)
    }

    // MARK: - Sending Messages

    private func sendNotification(method: MCPAppProtocol.Method, params: JSONValue) {
        let message = JSONRPCRequest(method: method.rawValue, params: params)
        postMessage(message)
    }

    private func sendRequest(method: MCPAppProtocol.Method, params: JSONValue) {
        let message = JSONRPCRequest(id: Int.random(in: 1...999_999), method: method.rawValue, params: params)
        postMessage(message)
    }

    private func sendSuccessResponse(id: Int, result: JSONValue) {
        let response = JSONRPCResponse(id: id, result: result)
        postResponse(response)
    }

    private func sendErrorResponse(id: Int, error: JSONRPCError) {
        let response = JSONRPCResponse(id: id, error: error)
        postResponse(response)
    }

    private func postMessage(_ message: JSONRPCRequest) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        let script = "window.postMessage(\(jsonString), '*');"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                Log.error("MCPAppBridge postMessage failed: \(error.localizedDescription)")
            }
        }
    }

    private func postResponse(_ response: JSONRPCResponse) {
        guard let data = try? JSONEncoder().encode(response),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        let script = "window.postMessage(\(jsonString), '*');"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                Log.error("MCPAppBridge postResponse failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Bridge Script

    private static let bridgeInjectionScript: String = """
        (function() {
            // Intercept postMessage calls from the MCP App SDK
            // The SDK calls window.parent.postMessage() but in WKWebView there's no parent frame.
            // We redirect to the native message handler.
            var originalPostMessage = window.postMessage.bind(window);

            // Override parent.postMessage to route to native
            Object.defineProperty(window, 'parent', {
                get: function() {
                    return {
                        postMessage: function(data, origin) {
                            if (data && data.jsonrpc === '2.0') {
                                window.webkit.messageHandlers.\(Constant.messageHandler).postMessage(data);
                            }
                        }
                    };
                },
                configurable: false
            });

            // Listen for messages posted by the native host
            // The host calls evaluateJavaScript("window.postMessage(...)") which fires this listener.
        })();
        """

    private enum Constant {
        static let messageHandler: String = "mcpBridge"
        static let hostName: String = "Convos"
        static let hostVersion: String = "1.0.0"
        static let allowedURLSchemes: Set<String> = ["https", "http"]
    }
}
