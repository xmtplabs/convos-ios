import Combine
import Foundation
import GRDB

protocol AuthorizeInboxOperationProtocol {
    func stopAndDelete() async
    func stopAndDelete()
    func stop()
}

final class AuthorizeInboxOperation: AuthorizeInboxOperationProtocol, @unchecked Sendable {
    let stateMachine: InboxStateMachine
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
        platformProviders: PlatformProviders
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
            platformProviders: platformProviders
        )
        operation.authorize(inboxId: inboxId, clientId: clientId)
        return operation
    }

    static func register(
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        networkMonitor: any NetworkMonitorProtocol = NetworkMonitor(),
        environment: AppEnvironment,
        platformProviders: PlatformProviders
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
            platformProviders: platformProviders
        )
        operation.register(clientId: clientId)
        return operation
    }

    private init(
        clientId: String,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        networkMonitor: any NetworkMonitorProtocol,
        environment: AppEnvironment,
        startsStreamingServices: Bool,
        overrideJWTToken: String? = nil,
        platformProviders: PlatformProviders
    ) {
        let syncingManager = startsStreamingServices ? SyncingManager(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            deviceRegistrationManager: DeviceRegistrationManager(
                environment: environment,
                platformProviders: platformProviders
            )
        ) : nil
        let invitesRepository = InvitesRepository(databaseReader: databaseReader)
        stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: identityStore,
            invitesRepository: invitesRepository,
            databaseWriter: databaseWriter,
            syncingManager: syncingManager,
            networkMonitor: networkMonitor,
            overrideJWTToken: overrideJWTToken,
            environment: environment,
            appLifecycle: platformProviders.appLifecycle
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

    private func authorize(inboxId: String, clientId: String) {
        let newTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await stateMachine.authorize(inboxId: inboxId, clientId: clientId)
        }
        cancelAndReplaceTask(with: newTask)
    }

    private func register(clientId: String) {
        let newTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await stateMachine.register(clientId: clientId)
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
}
