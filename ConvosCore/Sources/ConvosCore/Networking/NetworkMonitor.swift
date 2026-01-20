import Foundation
import Network

/// Protocol for network monitoring to enable testing
public protocol NetworkMonitorProtocol: Actor {
    var status: NetworkMonitor.Status { get async }
    var isConnected: Bool { get async }
    var statusSequence: AsyncStream<NetworkMonitor.Status> { get async }
    func start() async
    func stop() async
}

/// Monitors network connectivity using NWPathMonitor
///
/// NetworkMonitor provides reactive network status updates using Apple's Network framework.
/// It distinguishes between different connection types (WiFi, cellular, etc.) and provides
/// information about network constraints like expensive connections and Low Data Mode.
///
/// Usage:
/// ```swift
/// let monitor = NetworkMonitor()
/// monitor.start()
///
/// for await status in await monitor.statusSequence {
///     switch status {
///     case .connected(let type):
///         // Handle connection
///     case .disconnected:
///         // Handle disconnection
///     }
/// }
/// ```
public actor NetworkMonitor: NetworkMonitorProtocol {
    public enum Status: Sendable, Equatable {
        case connected(ConnectionType)
        case disconnected
        case connecting
        case unknown

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public enum ConnectionType: Sendable, Equatable {
        case wifi
        case cellular
        case wiredEthernet
        case other
    }

    private nonisolated let queue: DispatchQueue = DispatchQueue(label: "com.convos.networkmonitor", qos: .utility)
    private var monitor: NWPathMonitor?

    private var _status: Status = .unknown
    private var _currentPath: NWPath?
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]

    public var status: Status {
        _status
    }

    public var isConnected: Bool {
        _status.isConnected
    }

    public var isExpensive: Bool {
        _currentPath?.isExpensive ?? false
    }

    public var isConstrained: Bool {
        _currentPath?.isConstrained ?? false
    }

    public init() {}

    public func start() async {
        monitor?.cancel()
        let newMonitor = NWPathMonitor()
        monitor = newMonitor
        newMonitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                guard let self else { return }
                await self.handlePathUpdate(path)
            }
        }
        newMonitor.start(queue: queue)
        Log.info("Network monitor started")
    }

    public func stop() async {
        monitor?.cancel()
        monitor = nil
        for continuation in statusContinuations.values {
            continuation.finish()
        }
        statusContinuations.removeAll()
        _status = .unknown
        _currentPath = nil
        Log.info("Network monitor stopped")
    }

    private func handlePathUpdate(_ path: NWPath) {
        _currentPath = path

        let newStatus: Status

        switch path.status {
        case .satisfied:
            newStatus = .connected(connectionType(from: path))
        case .requiresConnection:
            newStatus = .connecting
        case .unsatisfied:
            newStatus = .disconnected
        @unknown default:
            newStatus = .disconnected
        }

        guard newStatus != _status else { return }

        let oldStatus = _status
        _status = newStatus

        Log.info("Network status: \(oldStatus) → \(newStatus)")

        if path.isExpensive {
            Log.info("Network is expensive (cellular/hotspot)")
        }
        if path.isConstrained {
            Log.info("Network is constrained (Low Data Mode)")
        }

        // Emit to all continuations
        for continuation in statusContinuations.values {
            continuation.yield(newStatus)
        }
    }

    private func connectionType(from path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wiredEthernet
        }
        return .other
    }

    public var statusSequence: AsyncStream<Status> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.addStatusContinuation(continuation)
            }
        }
    }

    private func addStatusContinuation(_ continuation: AsyncStream<Status>.Continuation) {
        let id = UUID()
        statusContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeStatusContinuation(id: id)
            }
        }
        continuation.yield(_status)
    }

    private func removeStatusContinuation(id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    deinit {
        monitor?.cancel()
    }
}
