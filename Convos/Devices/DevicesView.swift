// Devices screen — entry point for the device pairing flow.
//
// Reachable from AppSettingsView via the "Devices" row. Shows the
// current device plus any other installations registered under the
// user's inbox, and offers "Add new device" which presents the
// initiator pairing sheet.

import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

struct DevicesView: View {
    @State var viewModel: DevicesViewModel
    @State private var navState: DevicesNavigatorImpl = .init()
    @State private var navigator: DevicesCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = DevicesCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private func handlePairSheetChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(pairDevice: PairDeviceNavigatorArgs())
    }

    private func handleRemoveSheetChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        let deviceId: String = viewModel.devicePendingRemoval?.id ?? ""
        navigator?.present(removeDevice: RemoveDeviceNavigatorArgs(deviceId: deviceId))
    }

    var body: some View {
        devicesList
            .navigationTitle("Devices")
            .toolbarTitleDisplayMode(.inline)
            .onAppear {
                viewModel.startObserving()
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
            }
            .onChange(of: viewModel.showPairingSheet) { oldValue, newValue in
                handlePairSheetChanged(from: oldValue, to: newValue)
            }
            .onChange(of: viewModel.showRemoveDeviceSheet) { oldValue, newValue in
                handleRemoveSheetChanged(from: oldValue, to: newValue)
            }
            .selfSizingSheet(
                isPresented: $viewModel.showPairingSheet,
                onDismiss: {
                    viewModel.stopPairing()
                    viewModel.pairingViewModel = nil
                },
                content: {
                    if let pairingVM = viewModel.pairingViewModel {
                        PairingSheetView(viewModel: pairingVM)
                            .padding(.top, DesignConstants.Spacing.step5x)
                    }
                }
            )
            .selfSizingSheet(
                isPresented: $viewModel.showRemoveDeviceSheet,
                onDismiss: {
                    viewModel.devicePendingRemoval = nil
                },
                content: {
                    if let device = viewModel.devicePendingRemoval {
                        let removeAction = { viewModel.confirmRemoveDevice() }
                        let cancelAction = { viewModel.devicePendingRemoval = nil }
                        RemoveDeviceSheetView(
                            deviceName: device.name,
                            isRemoving: viewModel.isRemovingDevice,
                            onRemove: removeAction,
                            onCancel: cancelAction
                        )
                        .padding(.top, DesignConstants.Spacing.step5x)
                    }
                }
            )
            .accessibilityIdentifier("devices-view")
    }

    private var devicesList: some View {
        List {
            Section {
                ForEach(viewModel.devices) { device in
                    deviceRow(device)
                }
            } footer: {
                Text("Devices using this account")
            }

            if !viewModel.iCloudDevices.isEmpty {
                Section {
                    ForEach(viewModel.iCloudDevices) { backup in
                        iCloudDeviceRow(backup)
                    }
                } footer: {
                    Text("Other devices in iCloud")
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

    private func iCloudDeviceRow(_ backup: PairableDeviceBackup) -> some View {
        let pairAction = { viewModel.pairICloudDevice(backup) }
        let isMain: Bool = viewModel.mainDeviceInboxId == backup.inboxId
        return Button(action: pairAction) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: "icloud")
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.deviceName ?? DevicesViewModel.shortICloudDeviceName(inboxId: backup.inboxId))
                        .foregroundStyle(.colorTextPrimary)

                    if isMain {
                        Text("Main device")
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("icloud-device-row-\(backup.inboxId)")
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        let caption: String? = {
            guard device.isCurrentDevice else { return nil }
            return viewModel.currentDeviceIsMain ? "This device · Main device" : "This device"
        }()
        return HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "iphone.gen3")
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .foregroundStyle(.colorTextPrimary)

                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("device-row-\(device.id)")
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

#Preview("With Devices") {
    NavigationStack {
        DevicesView(viewModel: {
            let vm = DevicesViewModel(pairingServiceFactory: { MockPairingService() }, session: nil)
            vm.devices = [
                PairedDevice(id: "1", name: "Jarod's iPhone", isCurrentDevice: true, createdAt: nil),
                PairedDevice(id: "2", name: "Jarod's iPad", isCurrentDevice: false, createdAt: nil),
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
