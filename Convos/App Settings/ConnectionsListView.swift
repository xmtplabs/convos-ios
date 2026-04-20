import ConvosCore
import SwiftUI

struct ConnectionsListView: View {
    @Bindable var viewModel: ConnectionsListViewModel

    @State private var showingDisconnectAlert: Bool = false
    @State private var disconnectingConnectionId: String?

    var body: some View {
        List {
            headerSection

            if !viewModel.connections.isEmpty {
                connectedSection
            }

            availableSection
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
                        Text(connection.serviceName)
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
            let hasCalendar = viewModel.connections.contains { $0.serviceId == "googlecalendar" }

            if !hasCalendar {
                let action = { viewModel.connect(serviceId: "googlecalendar") }
                Button(action: action) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        connectionIcon(for: "googlecalendar")

                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                            Text("Google Calendar")
                                .font(.body)
                                .foregroundStyle(.colorTextPrimary)
                            Text("Share your calendar with conversations")
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
        } header: {
            Text("Available")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
    }

    @ViewBuilder
    private func connectionIcon(for serviceId: String) -> some View {
        Group {
            Image(systemName: iconName(for: serviceId))
                .font(.headline)
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .foregroundStyle(.white)
        }
        .frame(width: DesignConstants.Spacing.step10x, height: DesignConstants.Spacing.step10x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                .fill(iconColor(for: serviceId))
                .aspectRatio(1.0, contentMode: .fit)
        )
    }

    private func iconName(for serviceId: String) -> String {
        switch serviceId {
        case "googlecalendar":
            "calendar"
        default:
            "link"
        }
    }

    private func iconColor(for serviceId: String) -> Color {
        switch serviceId {
        case "googlecalendar":
            .blue
        default:
            .gray
        }
    }
}
