import ConvosCore
import SwiftUI

struct ConnectionsListView: View {
    @Bindable var viewModel: ConnectionsListViewModel

    @State private var showingDisconnectAlert: Bool = false
    @State private var disconnectingConnectionId: String?

    private var availableServices: [ConnectionServiceInfo] {
        let activeIds = Set(viewModel.connections.map(\.serviceId))
        return ConnectionServiceCatalog.all.filter { !activeIds.contains($0.id) }
    }

    var body: some View {
        List {
            headerSection

            if !viewModel.connections.isEmpty {
                connectedSection
            }

            if !availableServices.isEmpty {
                availableSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .task {
            viewModel.refresh()
        }
        .alert("Disconnect", isPresented: $showingDisconnectAlert) {
            let dismissAction = {
                disconnectingConnectionId = nil
            }
            Button("Cancel", role: .cancel, action: dismissAction)
            let confirmAction = {
                if let id = disconnectingConnectionId {
                    viewModel.disconnect(id)
                }
                disconnectingConnectionId = nil
            }
            Button("Disconnect", role: .destructive, action: confirmAction)
        } message: {
            Text("This will revoke access for all conversations using this connection.")
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Connections")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
                Text("Share services with conversations")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
        .listRowSpacing(0.0)
        .listRowInsets(.all, DesignConstants.Spacing.step2x)
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }

    private var connectedSection: some View {
        Section {
            ForEach(viewModel.connections) { connection in
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    connectionIcon(for: connection.serviceId)

                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text(ConnectionServiceCatalog.displayName(for: connection.serviceId, fallback: connection.serviceName))
                            .font(.body)
                            .foregroundStyle(.colorTextPrimary)
                        Text("Connected")
                            .font(.footnote)
                            .foregroundStyle(.colorTextSecondary)
                    }

                    Spacer()

                    let action = {
                        disconnectingConnectionId = connection.id
                        showingDisconnectAlert = true
                    }
                    Button(action: action) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Active")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private var availableSection: some View {
        Section {
            ForEach(availableServices) { service in
                availableRow(for: service)
            }
        } header: {
            Text("Available")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
    }

    @ViewBuilder
    private func availableRow(for service: ConnectionServiceInfo) -> some View {
        let action = { viewModel.connect(serviceId: service.id) }
        Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                connectionIcon(for: service.id)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(service.displayName)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Text(service.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }

                Spacer()

                if viewModel.isConnecting {
                    ProgressView()
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.colorFillPrimary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isConnecting)
    }

    @ViewBuilder
    private func connectionIcon(for serviceId: String) -> some View {
        let info = ConnectionServiceCatalog.info(for: serviceId)
        Group {
            Image(systemName: info?.iconSystemName ?? "link")
                .font(.headline)
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .foregroundStyle(.white)
        }
        .frame(width: DesignConstants.Spacing.step10x, height: DesignConstants.Spacing.step10x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                .fill(info?.iconBackgroundColor ?? .gray)
                .aspectRatio(1.0, contentMode: .fit)
        )
    }
}
