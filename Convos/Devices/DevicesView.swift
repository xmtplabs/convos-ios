import ConvosCore
import SwiftUI

struct DevicesView: View {
    @State var viewModel: DevicesViewModel

    var body: some View {
        content
            .navigationTitle("Devices")
            .toolbarTitleDisplayMode(.inline)
            .task {
                await viewModel.loadDevices()
            }
            .selfSizingSheet(isPresented: $viewModel.showPairingSheet, onDismiss: {
                viewModel.stopPairing()
                viewModel.pairingViewModel = nil
            }, content: {
                if let pairingVM = viewModel.pairingViewModel {
                    PairingSheetView(viewModel: pairingVM)
                        .padding(.top, DesignConstants.Spacing.step5x)
                }
            })
            .accessibilityIdentifier("devices-view")
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.devices.isEmpty && !viewModel.isLoading {
            emptyState
        } else {
            devicesList
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Spacer()

            Image(systemName: "iphone.gen3.sizes")
                .font(.system(size: 48))
                .foregroundStyle(.colorTextTertiary)

            Text("No other devices")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)

            Text("Pair another device to sync your conversations and keys across devices.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignConstants.Spacing.step8x)

            let addAction = { viewModel.startPairing() }
            Button(action: addAction) {
                Text("Add new device")
            }
            .convosButtonStyle(.rounded(fullWidth: false))
            .accessibilityIdentifier("add-new-device-button")
            .padding(.top, DesignConstants.Spacing.step2x)

            Spacer()
        }
    }

    private var devicesList: some View {
        List {
            Section {
                ForEach(viewModel.devices, id: \.inboxId) { device in
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(.colorTextPrimary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .foregroundStyle(.colorTextPrimary)

                            if device.isCurrentDevice {
                                Text("This device")
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                            }
                        }

                        Spacer()
                    }
                    .accessibilityIdentifier("device-row-\(device.inboxId)")
                }
            }

            Section {
                let addAction = { viewModel.startPairing() }
                Button(action: addAction) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.colorFillPrimary)

                        Text("Add new device")
                            .foregroundStyle(.colorFillPrimary)
                    }
                }
                .accessibilityIdentifier("add-device-button")
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
    }
}

#Preview("Empty") {
    NavigationStack {
        DevicesView(viewModel: DevicesViewModel(session: MockInboxesService()))
    }
}

#Preview("With Devices") {
    NavigationStack {
        DevicesView(viewModel: {
            let vm = DevicesViewModel(session: MockInboxesService())
            vm.devices = [
                VaultDevice(inboxId: "1", name: "Jarod's iPhone", isCurrentDevice: true),
                VaultDevice(inboxId: "2", name: "Jarod's iPad", isCurrentDevice: false),
            ]
            return vm
        }())
    }
}
