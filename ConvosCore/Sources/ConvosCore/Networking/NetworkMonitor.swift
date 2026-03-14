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
    private var isStarted: Bool = false

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
        isStarted = true
        let newMonitor = NWPathMonitor()
        monitor = newMonitor
        newMonitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                guard let self else { return }
                await self.handlePathUpdate(path)
            }
        }
        newMonitor.start(queue: queue)
        Log.debug("Network monitor started")
    }

    public func stop() async {
        monitor?.cancel()
        monitor = nil
        isStarted = false
        for continuation in statusContinuations.values {
            continuation.finish()
        }
        statusContinuations.removeAll()
        _status = .unknown
        _currentPath = nil
        Log.debug("Network monitor stopped")
    }

    private func handlePathUpdate(_ path: NWPath) {
        guard isStarted else { return }

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

        Log.debug("Network status: \(oldStatus) → \(newStatus)")

        if path.isExpensive {
            Log.debug("Network is expensive (cellular/hotspot)")
        }
        if path.isConstrained {
            Log.debug("Network is constrained (Low Data Mode)")
        }

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
        let id = UUID()
        let currentStatus = _status
        return AsyncStream { [weak self] continuation in
            continuation.yield(currentStatus)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeStatusContinuation(id: id)
                }
            }
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.registerContinuation(continuation, id: id)
            }
        }
    }

    private func registerContinuation(_ continuation: AsyncStream<Status>.Continuation, id: UUID) {
        statusContinuations[id] = continuation
    }

    private func removeStatusContinuation(id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    deinit {
        monitor?.cancel()
    }
}
