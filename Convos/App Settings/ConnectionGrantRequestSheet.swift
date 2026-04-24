import Combine
import ConvosCore
import ConvosCoreiOS
import SwiftUI

struct PendingGrantRequest: Identifiable, Hashable {
    let serviceId: String
    let conversationId: String

    var id: String { "\(serviceId)-\(conversationId)" }
}

@MainActor @Observable
final class ConnectionGrantRequestSheetViewModel {
    private(set) var connection: Connection?
    private(set) var isLoading: Bool = true
    private(set) var isBusy: Bool = false
    private(set) var error: Error?
    private(set) var didComplete: Bool = false

    let serviceId: String
    let conversationId: String

    private let session: any SessionManagerProtocol
    private let connectionManager: any ConnectionManagerProtocol
    private let connectionRepository: any ConnectionRepositoryProtocol
    private var cancellable: AnyCancellable?

    init(
        serviceId: String,
        conversationId: String,
        session: any SessionManagerProtocol
    ) {
        self.serviceId = serviceId
        self.conversationId = conversationId
        self.session = session

        let oauthProvider: any OAuthSessionProvider = IOSOAuthSessionProvider()
        let callbackScheme = ConfigManager.shared.appUrlScheme
        self.connectionManager = session.connectionManager(
            oauthProvider: oauthProvider,
            callbackURLScheme: callbackScheme
        )
        self.connectionRepository = session.connectionRepository()

        cancellable = connectionRepository.connectionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.connection = connections.first { $0.serviceId == self?.serviceId }
                self?.isLoading = false
            }
    }

    private func resolveGrantWriter() -> any ConnectionGrantWriterProtocol {
        session.messagingService().connectionGrantWriter()
    }

    var displayName: String {
        ConnectionServiceCatalog.displayName(for: serviceId, fallback: connection?.serviceName)
    }

    var hasConnection: Bool {
        connection != nil
    }

    func share() {
        guard let connection else { return }
        isBusy = true
        error = nil
        Task {
            do {
                let writer = resolveGrantWriter()
                try await writer.grantConnection(connection.id, to: conversationId)
                didComplete = true
            } catch {
                self.error = error
            }
            isBusy = false
        }
    }

    func connectAndShare() {
        isBusy = true
        error = nil
        Task {
            do {
                let newConnection = try await connectionManager.connect(serviceId: serviceId)
                let writer = resolveGrantWriter()
                try await writer.grantConnection(newConnection.id, to: conversationId)
                didComplete = true
            } catch let oauthError as OAuthError {
                if case .cancelled = oauthError {
                    // user cancelled OAuth, leave sheet open
                } else {
                    self.error = oauthError
                }
            } catch {
                self.error = error
            }
            isBusy = false
        }
    }
}

enum GrantSheetError: LocalizedError {
    case inboxNotFound

    var errorDescription: String? {
        switch self {
        case .inboxNotFound:
            "Couldn't find the inbox for this conversation."
        }
    }
}

struct ConnectionGrantRequestSheet: View {
    @Bindable var viewModel: ConnectionGrantRequestSheetViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            icon

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .multilineTextAlignment(.center)

                Text(bodyText)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)

            if let error = viewModel.error {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
            }

            actionButtons
        }
        .padding(.vertical, DesignConstants.Spacing.step6x)
        .onChange(of: viewModel.didComplete) { _, didComplete in
            if didComplete { onDismiss() }
        }
    }

    private var icon: some View {
        let info = ConnectionServiceCatalog.info(for: viewModel.serviceId)
        return Image(systemName: info?.iconSystemName ?? "link")
            .font(.largeTitle)
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(info?.iconBackgroundColor ?? .gray)
            )
    }

    private var headline: String {
        viewModel.hasConnection ? "Share \(viewModel.displayName)?" : "Connect \(viewModel.displayName)?"
    }

    private var bodyText: String {
        if viewModel.hasConnection {
            return "The assistant will be able to use \(viewModel.displayName) in this conversation."
        } else {
            return "You haven't connected \(viewModel.displayName) yet. Connect it now to share with this conversation."
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            primaryButton
            cancelButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let isLoading = viewModel.isLoading || viewModel.isBusy
        let title = viewModel.hasConnection ? "Share" : "Connect and Share"
        let primaryAction = {
            if viewModel.hasConnection {
                viewModel.share()
            } else {
                viewModel.connectAndShare()
            }
        }
        Button(action: primaryAction) {
            HStack {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .background(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular).fill(Color.colorFillPrimary))
        }
        .disabled(isLoading)
    }

    @ViewBuilder
    private var cancelButton: some View {
        let cancelAction = onDismiss
        Button(action: cancelAction) {
            Text("Cancel")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
        }
        .disabled(viewModel.isBusy)
    }
}
