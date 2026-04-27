import Combine
import Foundation
import GRDB

protocol AuthorizeInboxOperationProtocol {
    func stopAndDelete() async
    func stopAndDelete()
    func stop()
    func stop() async
}

/// @unchecked Sendable: Thread safety is ensured via NSLock protecting the mutable `_task`
/// property. The `stateMachine` is an actor (inherently thread-safe). The `cancellables`
/// Set is only modified during initialization. All task operations use `cancelAndReplaceTask`
/// which acquires the lock before any mutation.
final class AuthorizeInboxOperation: AuthorizeInboxOperationProtocol, @unchecked Sendable {
    let stateMachine: SessionStateMachine
    private var cancellables: Set<AnyCancellable> = []
    private let taskLock: NSLock = NSLock()
    private var _task: Task<Void, Never>?

    private var task: Task<Void, Never>? {
        get {
            taskLock.lock()
            defer { taskLock.unlock() }
            return _task
        }
        set {
            taskLock.lock()
            defer { taskLock.unlock() }
            _task = newValue
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func authorize(
        inboxId: String,
        clientId: String,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        networkMonitor: any NetworkMonitorProtocol = NetworkMonitor(),
        environment: AppEnvironment,
        startsStreamingServices: Bool,
        overrideJWTToken: String? = nil,
        platformProviders: PlatformProviders,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        apiClient: (any ConvosAPIClientProtocol)? = nil,
        messagingClientFactory: (any MessagingClientFactory)? = nil
    ) -> AuthorizeInboxOperation {
        let operation = AuthorizeInboxOperation(
            clientId: clientId,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            networkMonitor: networkMonitor,
            environment: environment,
            startsStreamingServices: startsStreamingServices,
            overrideJWTToken: overrideJWTToken,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient,
            messagingClientFactory: messagingClientFactory
        )
        operation.authorize(inboxId: inboxId)
        return operation
    }

    static func register(
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        networkMonitor: any NetworkMonitorProtocol = NetworkMonitor(),
        environment: AppEnvironment,
        platformProviders: PlatformProviders,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
        apiClient: (any ConvosAPIClientProtocol)? = nil,
        messagingClientFactory: (any MessagingClientFactory)? = nil
    ) -> AuthorizeInboxOperation {
        // Generate clientId before creating state machine
        let clientId = ClientId.generate().value
        let operation = AuthorizeInboxOperation(
            clientId: clientId,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            networkMonitor: networkMonitor,
            environment: environment,
            startsStreamingServices: true,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient,
            messagingClientFactory: messagingClientFactory
        )
        operation.register()
        return operation
    }

    // swiftlint:disable:next function_parameter_count
    private init(
        clientId: String,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        networkMonitor: any NetworkMonitorProtocol,
        environment: AppEnvironment,
        startsStreamingServices: Bool,
        overrideJWTToken: String? = nil,
        platformProviders: PlatformProviders,
        deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)?,
        apiClient: (any ConvosAPIClientProtocol)?,
        messagingClientFactory: (any MessagingClientFactory)?
    ) {
        let syncingManager = startsStreamingServices ? SyncingManager(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            deviceRegistrationManager: deviceRegistrationManager,
            notificationCenter: platformProviders.notificationCenter
        ) : nil
        let invitesRepository = InvitesRepository(databaseReader: databaseReader)
        // Note: `messagingClientFactory` is currently unused; dev's
        // post-merge SessionStateMachine talks directly to
        // `XMTPiOS.Client.create` / `Client.build` and wraps the result
        // in `XMTPiOSMessagingClient`. The factory hook is preserved on
        // this initializer so the eventual DTU-lane re-wiring can land
        // without a public API change.
        _ = messagingClientFactory
        stateMachine = SessionStateMachine(
            clientId: clientId,
            identityStore: identityStore,
            invitesRepository: invitesRepository,
            databaseWriter: databaseWriter,
            syncingManager: syncingManager,
            networkMonitor: networkMonitor,
            overrideJWTToken: overrideJWTToken,
            environment: environment,
            appLifecycle: platformProviders.appLifecycle,
            apiClient: apiClient
        )
    }

    deinit {
        cancelAndReplaceTask(with: nil)
    }

    /// Atomically cancels the current task and replaces it with a new one
    private func cancelAndReplaceTask(with newTask: Task<Void, Never>?) {
        taskLock.lock()
        defer { taskLock.unlock() }
        _task?.cancel()
        _task = newTask
    }

    private func authorize(inboxId: String) {
        let newTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await stateMachine.authorize(inboxId: inboxId)
        }
        cancelAndReplaceTask(with: newTask)
    }

    private func register() {
        let newTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await stateMachine.register()
        }
        cancelAndReplaceTask(with: newTask)
    }

    func stopAndDelete() {
        let newTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await stateMachine.stopAndDelete()
        }
        cancelAndReplaceTask(with: newTask)
    }

    func stopAndDelete() async {
        cancelAndReplaceTask(with: nil)
        await stateMachine.stopAndDelete()
    }

    func stop() {
        let newTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await stateMachine.stop()
        }
        cancelAndReplaceTask(with: newTask)
    }

    func stop() async {
        cancelAndReplaceTask(with: nil)
        await stateMachine.stop()
    }
}
