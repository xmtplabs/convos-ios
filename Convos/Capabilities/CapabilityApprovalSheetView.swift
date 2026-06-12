import ConvosConnections
import ConvosCore
import SwiftUI

/// Connection approval sheet (Figma frame 4899/4313), presented when the user
/// taps a pending capability connect pill in the transcript: branded service
/// header, the catalog-driven permission bundle rows with wide toggles, and a
/// single Done button that approves the request.
///
/// The Figma layout only covers the single-linked-provider + catalog-bundles
/// shape (`.confirm`). Every other picker variant (provider choice,
/// connect-and-approve, bundle-less services) falls back to the existing
/// `CapabilityPickerCardView` inside the same sheet so no flow loses its UI.
struct CapabilityApprovalSheetView: View {
    let layout: CapabilityPickerLayout
    let agentName: String?
    let onApprove: (Set<ProviderID>, [String: Set<String>]) -> Void
    let onDeny: () -> Void
    let onConnect: (ProviderID) -> Void

    var body: some View {
        if let content = BundleApprovalContent(layout: layout) {
            BundleApprovalSheetContent(
                content: content,
                agentName: agentName,
                onApprove: onApprove
            )
            // Reseed the toggle state if a newer request replaces the layout
            // while the sheet is up — @State survives re-render otherwise.
            .id(layout.request.requestId)
        } else {
            CapabilityPickerCardView(
                layout: layout,
                agentName: agentName,
                onApprove: onApprove,
                onDeny: onDeny,
                onConnect: onConnect
            )
            .padding(.vertical, DesignConstants.Spacing.step6x)
        }
    }
}

/// The single-provider, catalog-bundle shape the Figma sheet renders.
private struct BundleApprovalContent {
    let provider: CapabilityPickerLayout.ProviderSummary
    let group: CapabilityPickerLayout.ServiceBundles

    init?(layout: CapabilityPickerLayout) {
        guard layout.variant == .confirm,
              layout.defaultSelection.count == 1,
              let providerId = layout.defaultSelection.first,
              let provider = layout.providers.first(where: { $0.id == providerId }),
              provider.linked,
              let group = layout.serviceBundles.first(where: { $0.providerId == providerId }),
              !group.rows.isEmpty else {
            return nil
        }
        self.provider = provider
        self.group = group
    }
}

private struct BundleApprovalSheetContent: View {
    let content: BundleApprovalContent
    let agentName: String?
    let onApprove: (Set<ProviderID>, [String: Set<String>]) -> Void

    /// All rows start ON: the user expressed intent by tapping the connect
    /// pill, so the sheet is a confirmation with per-bundle opt-out (the
    /// catalog's defaultEnabled seeds the out-of-band card flow instead).
    @State private var enabledBundleIds: Set<String>

    init(
        content: BundleApprovalContent,
        agentName: String?,
        onApprove: @escaping (Set<ProviderID>, [String: Set<String>]) -> Void
    ) {
        self.content = content
        self.agentName = agentName
        self.onApprove = onApprove
        _enabledBundleIds = State(initialValue: Set(content.group.rows.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
            header
            permissionsSection
            doneButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.top, DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step6x)
        .sheetDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            serviceIcon

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("\(agentName ?? "Agent") can use your")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                Text(content.provider.displayName)
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var serviceIcon: some View {
        if let assetName = ConnectionServiceIcon.assetName(forServiceId: content.provider.id.cloudServiceId) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: Constant.iconSize, height: Constant.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                        .stroke(Color.colorBorderEdge, lineWidth: Constant.iconBorderWidth)
                )
        } else {
            Image(systemName: content.provider.iconName.isEmpty ? "link" : content.provider.iconName)
                .font(.title)
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.iconSize, height: Constant.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                        .fill(Color.colorFillMinimal)
                )
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Permissions requested")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)

            VStack(spacing: Constant.rowGap) {
                ForEach(content.group.rows, id: \.id) { row in
                    permissionRow(row)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        }
    }

    private func permissionRow(_ row: CapabilityPickerLayout.ServiceBundles.Row) -> some View {
        let binding: Binding<Bool> = bundleBinding(row.id)
        return HStack(spacing: DesignConstants.Spacing.step2x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                if !row.description.isEmpty {
                    Text(row.description)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            Spacer(minLength: 0)
            Toggle(row.title, isOn: binding)
                .toggleStyle(WideSwitchToggleStyle())
                .labelsHidden()
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorBackgroundSurfaceless)
    }

    private var doneButton: some View {
        let approveAction: () -> Void = {
            onApprove([content.provider.id], [content.group.serviceId: enabledBundleIds])
        }
        // An empty toggle set must never approve: it would read as consent
        // while granting nothing (and an empty bundle list is forbidden to
        // ever reach the grant writer).
        return Button("Done", action: approveAction)
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(enabledBundleIds.isEmpty)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private func bundleBinding(_ bundleId: String) -> Binding<Bool> {
        Binding(
            get: { enabledBundleIds.contains(bundleId) },
            set: { isOn in
                if isOn {
                    enabledBundleIds.insert(bundleId)
                } else {
                    enabledBundleIds.remove(bundleId)
                }
            }
        )
    }

    private enum Constant {
        static let titleSize: CGFloat = 40.0
        static let iconSize: CGFloat = 56.0
        static let iconBorderWidth: CGFloat = 0.4
        static let rowGap: CGFloat = 1.0
    }
}

/// The design system's wide switch (68x28 track, 39x24 knob) from the Figma
/// permission row — a stock `UISwitch` is 51x31 and visibly different.
private struct WideSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let action = { configuration.isOn.toggle() }
        return Button(action: action) {
            RoundedRectangle(cornerRadius: Constant.trackCornerRadius)
                .fill(configuration.isOn ? Color.colorFillPrimary : Color.colorFillTertiary)
                .frame(width: Constant.trackWidth, height: Constant.trackHeight)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: Constant.trackCornerRadius)
                        .fill(.white)
                        .frame(width: Constant.knobWidth, height: Constant.knobHeight)
                        .shadow(color: .colorDarkAlpha15, radius: 4.0, x: 0.0, y: 2.0)
                        .padding(Constant.knobInset)
                }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2), value: configuration.isOn)
        .accessibilityAddTraits(.isToggle)
    }

    private enum Constant {
        static let trackWidth: CGFloat = 68.0
        static let trackHeight: CGFloat = 28.0
        static let trackCornerRadius: CGFloat = 16.0
        static let knobWidth: CGFloat = 39.0
        static let knobHeight: CGFloat = 24.0
        static let knobInset: CGFloat = 2.0
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Bundle approval (Google Calendar)") {
    CapabilityApprovalSheetView(
        layout: CapabilityPickerLayout(
            request: CapabilityRequest(
                requestId: "preview-1",
                askerInboxId: "preview-asker",
                subject: .calendar,
                capability: .read,
                rationale: "To book that meeting"
            ),
            variant: .confirm,
            providers: [
                CapabilityPickerLayout.ProviderSummary(
                    id: ProviderID(rawValue: "composio.googlecalendar"),
                    displayName: "Google Calendar",
                    iconName: "calendar",
                    subject: .calendar,
                    linked: true,
                    supportsCapability: true
                ),
            ],
            defaultSelection: [ProviderID(rawValue: "composio.googlecalendar")],
            serviceBundles: [
                CapabilityPickerLayout.ServiceBundles(
                    providerId: ProviderID(rawValue: "composio.googlecalendar"),
                    serviceId: "googlecalendar",
                    serviceVersion: 5,
                    rows: [
                        .init(
                            id: "calendar.events",
                            title: "Events",
                            description: "View and edit events on all calendars",
                            defaultEnabled: false
                        ),
                    ]
                ),
            ]
        ),
        agentName: "Assistant",
        onApprove: { _, _ in },
        onDeny: {},
        onConnect: { _ in }
    )
}
#endif
