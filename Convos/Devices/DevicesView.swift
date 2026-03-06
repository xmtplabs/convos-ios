import ConvosCore
import SwiftUI

struct DevicesView: View {
    @State var viewModel: DevicesViewModel

    var body: some View {
        content
            .navigationTitle("Devices")
            .toolbarTitleDisplayMode(.inline)
            .onAppear {
                viewModel.startObserving()
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
            .selfSizingSheet(isPresented: $viewModel.showRemoveDeviceSheet, onDismiss: {
                viewModel.devicePendingRemoval = nil
            }, content: {
                if let device = viewModel.devicePendingRemoval {
                    RemoveDeviceSheetView(
                        deviceName: device.name,
                        isRemoving: viewModel.isRemovingDevice,
                        onRemove: { viewModel.confirmRemoveDevice() },
                        onCancel: { viewModel.devicePendingRemoval = nil }
                    )
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
                    deviceRow(device)
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

    private func deviceRow(_ device: VaultDevice) -> some View {
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
        .contentShape(Rectangle())
        .accessibilityIdentifier("device-row-\(device.inboxId)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !device.isCurrentDevice {
                let deleteAction = { viewModel.devicePendingRemoval = device }
                Button(action: deleteAction) {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .contextMenu {
            if !device.isCurrentDevice {
                let deleteAction = { viewModel.devicePendingRemoval = device }
                Button(role: .destructive, action: deleteAction) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Remove Device Sheet

private struct RemoveDeviceSheetView: View {
    let deviceName: String
    let isRemoving: Bool
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Remove \(deviceName)?")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("This will lock the device out of all conversations.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step4x) {
                holdToDeleteButton

                let cancelAction = { onCancel() }
                Button(action: cancelAction) {
                    Text("Cancel")
                }
                .convosButtonStyle(.text)
                .disabled(isRemoving)
                .hoverEffect(.lift)
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }

    private var holdToDeleteButton: some View {
        Button {
            onRemove()
        } label: {
            ZStack {
                Text("Hold to delete")
                    .opacity(isRemoving ? 0 : 1)
                Text("Removing...")
                    .opacity(isRemoving ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: isRemoving)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .disabled(isRemoving)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: {
            var config = HoldToConfirmStyleConfig.default
            config.duration = 3.0
            config.backgroundColor = .colorCaution
            return config
        }()))
        .hoverEffect(.lift)
        .accessibilityIdentifier("hold-to-delete-device-button")
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

#Preview("Remove Device Sheet") {
    RemoveDeviceSheetView(
        deviceName: "Jarod's iPad",
        isRemoving: false,
        onRemove: {},
        onCancel: {}
    )
}
