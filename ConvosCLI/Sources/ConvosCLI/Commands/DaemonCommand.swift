import ArgumentParser
import ConvosCore
import Foundation
import Hummingbird
import NIOCore

struct Daemon: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run as a daemon with HTTP JSON-RPC and SSE endpoints"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "HTTP port to listen on")
    var httpPort: Int = 8080

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    mutating func run() async throws {
        let context = try await CLIContext.shared(
            dataDir: options.dataDir,
            environment: options.environment,
            verbose: options.verbose
        )

        // Create handlers
        let jsonrpcHandler = JSONRPCHandler(context: context)
        let sseHandler = SSEHandler(context: context)

        print("Starting Convos CLI daemon...")
        print("Environment: \(options.environment)")
        print("Listening on http://\(host):\(httpPort)")
        print("")
        print("Endpoints:")
        print("  POST /jsonrpc - JSON-RPC 2.0 endpoint")
        print("  GET /events   - SSE message stream")
        print("  GET /health   - Health check")
        print("")
        print("Available JSON-RPC methods:")
        print("  conversations.list    - List all conversations")
        print("  conversations.create  - Create new conversation")
        print("  conversations.join    - Join via invite")
        print("  conversations.invite  - Get invite for conversation")
        print("  messages.list         - List messages in conversation")
        print("  messages.send         - Send a message")
        print("  messages.react        - Add/remove reaction")
        print("  account.info          - Get account info")
        print("")
        print("Press Ctrl+C to stop")

        // Create router
        let router = Router()

        // JSON-RPC endpoint
        router.post("/jsonrpc") { request, _ -> Response in
            do {
                // Collect body
                let body = request.body
                let buffer = try await body.collect(upTo: 1024 * 1024) // 1MB max

                // Decode request
                let decoder = JSONDecoder()
                let rpcRequest: JSONRPCRequest
                do {
                    rpcRequest = try decoder.decode(JSONRPCRequest.self, from: buffer)
                } catch {
                    let response = JSONRPCResponse(
                        error: JSONRPCError.parseError.object,
                        id: nil
                    )
                    return try encodeResponse(response)
                }

                // Handle request
                let response = await jsonrpcHandler.handle(rpcRequest)
                return try encodeResponse(response)
            } catch {
                let response = JSONRPCResponse(
                    error: JSONRPCError.internalError(error.localizedDescription).object,
                    id: nil
                )
                return (try? encodeResponse(response)) ?? Response(status: .internalServerError)
            }
        }

        // SSE endpoint
        router.get("/events") { _, _ -> Response in
            let eventStream = await sseHandler.streamWithHeartbeat(interval: 30)

            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/event-stream",
                    .cacheControl: "no-cache",
                    .connection: "keep-alive"
                ],
                body: ResponseBody(asyncSequence: eventStream)
            )
        }

        // Health check
        router.get("/health") { _, _ in
            Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: """
                {"status":"ok","version":"1.0.0"}
                """))
            )
        }

        // Create and run app
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: httpPort)
            )
        )

        try await app.runService()
    }
}

// MARK: - Helpers

private func encodeResponse(_ response: JSONRPCResponse) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(response)

    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: data))
    )
}
