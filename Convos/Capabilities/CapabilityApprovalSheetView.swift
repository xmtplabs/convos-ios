import ConvosConnections
import ConvosCore
import SwiftUI

/// Connection approval sheet (Figma frame 4899/4313), presented when the user
/// taps a pending capability connect pill in the transcript: branded service
/// header, the catalog-driven permission bundle rows with wide toggles, and a
/// single primary button that approves the request.
///
/// This is the ONLY approval surface — every `CapabilityPickerLayout` variant
/// renders here, including pre-connect requests (`connectAndApprove` /
/// unlinked providers): the primary button reads "Connect" and the approve
/// callback runs the OS prompt / OAuth FIRST, sending the grant (with the
/// toggle state below) only after the connect succeeds. Layouts with more
/// than one candidate provider add a chooser section in the same grouped-row
/// style; layouts without catalog bundles simply omit the permissions section.
///
/// Done-as-revoke: when the asking agent already holds a grant for a service,
/// the toggles seed from the granted state, and turning them ALL off does NOT
/// disable the button — tapping it then revokes that grant (the view model
/// splits per service). Without an existing grant, all-off + Done is a
/// decline-style no-op dismiss; an empty bundle selection never turns into a
/// grant.
struct CapabilityApprovalSheetView: View {
    let layout: CapabilityPickerLayout
    let agentName: String?
    let onApprove: (Set<ProviderID>, [String: Set<String>]) -> Void

    var body: some View {
        ApprovalSheetContent(
            layout: layout,
            agentName: agentName,
            onApprove: onApprove
        )
        // Reseed the selection state if a newer request replaces the layout
        // while the sheet is up — @State survives re-render otherwise.
        .id(layout.request.requestId)
    }

    // MARK: - Seeding (internal for unit tests)

    /// Providers the sheet offers. Consent shapes (`confirm` / `verbConsent`)
    /// are locked to the layout's default selection; picker shapes offer every
    /// provider that can fulfill the verb (linked or not — unlinked ones
    /// connect on approve).
    static func selectableProviders(
        for layout: CapabilityPickerLayout
    ) -> [CapabilityPickerLayout.ProviderSummary] {
        let eligible = layout.providers.filter(\.supportsCapability)
        switch layout.variant {
        case .confirm, .verbConsent:
            return eligible.filter { layout.defaultSelection.contains($0.id) }
        case .singleSelect, .multiSelect, .connectAndApprove:
            return eligible
        }
    }

    static func seedSelection(for layout: CapabilityPickerLayout) -> Set<ProviderID> {
        let selectable = selectableProviders(for: layout)
        // A sole candidate is preselected even when the layout carries no
        // default (a pre-connect `connectAndApprove` has none) — the pill the
        // user tapped already named this service.
        if selectable.count == 1, let only = selectable.first {
            return [only.id]
        }
        return layout.defaultSelection
    }

    /// Toggle seed per service. With an existing grant the rows mirror the
    /// granted state (granted ids ON, the rest OFF — ids the catalog no
    /// longer knows are dropped), so unchecking reads as an explicit revoke
    /// of what stands today. Without a grant every row seeds ON: the user
    /// expressed intent by tapping the connect pill, the sheet is a
    /// confirmation with per-bundle opt-out.
    static func seedBundleSelection(for layout: CapabilityPickerLayout) -> [String: Set<String>] {
        var seed: [String: Set<String>] = [:]
        for group in layout.serviceBundles {
            let allRowIds = Set(group.rows.map(\.id))
            if let granted = group.grantedBundleIds {
                seed[group.serviceId] = granted.intersection(allRowIds)
            } else {
                seed[group.serviceId] = allRowIds
            }
        }
        return seed
    }
}

private struct ApprovalSheetContent: View {
    let layout: CapabilityPickerLayout
    let agentName: String?
    let onApprove: (Set<ProviderID>, [String: Set<String>]) -> Void

    @State private var selection: Set<ProviderID>
    /// Toggled-on bundle ids per service id, seeded by
    /// `CapabilityApprovalSheetView.seedBundleSelection`: the granted state
    /// when the agent already holds a grant, all-ON otherwise.
    @State private var enabledBundleIds: [String: Set<String>]

    init(
        layout: CapabilityPickerLayout,
        agentName: String?,
        onApprove: @escaping (Set<ProviderID>, [String: Set<String>]) -> Void
    ) {
        self.layout = layout
        self.agentName = agentName
        self.onApprove = onApprove
        _selection = State(initialValue: CapabilityApprovalSheetView.seedSelection(for: layout))
        _enabledBundleIds = State(initialValue: CapabilityApprovalSheetView.seedBundleSelection(for: layout))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
            header
            if singleProvider == nil && !selectableProviders.isEmpty {
                providerSection
            }
            if !selectedBundleGroups.isEmpty {
                permissionsSection
            }
            approveButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.top, DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step6x)
        .sheetDragIndicator(.visible)
        // `@State` initialValue runs once per view identity. The identity is
        // keyed by requestId above, but the SAME request's layout can change
        // content (a recompute after a failed OAuth, a provider linking from
        // elsewhere) — resync the seeds so stale rows don't stay checked.
        .onChange(of: layout.defaultSelection) { _, _ in
            selection = CapabilityApprovalSheetView.seedSelection(for: layout)
        }
        .onChange(of: layout.serviceBundles) { _, _ in
            enabledBundleIds = CapabilityApprovalSheetView.seedBundleSelection(for: layout)
        }
    }

    // MARK: - Derived state

    /// Providers the sheet offers. Consent shapes (`confirm` / `verbConsent`)
    /// are locked to the layout's default selection; picker shapes offer every
    /// provider that can fulfill the verb (linked or not — unlinked ones
    /// connect on approve).
    private var selectableProviders: [CapabilityPickerLayout.ProviderSummary] {
        CapabilityApprovalSheetView.selectableProviders(for: layout)
    }

    /// Non-nil when the sheet renders the pure Figma single-service shape.
    private var singleProvider: CapabilityPickerLayout.ProviderSummary? {
        let selectable = selectableProviders
        return selectable.count == 1 ? selectable.first : nil
    }

    /// Read federation is the only multi-provider grant; everything else picks one.
    private var allowsMultipleSelection: Bool {
        layout.variant == .multiSelect ||
            (layout.variant == .verbConsent && layout.defaultSelection.count > 1)
    }

    private var selectedBundleGroups: [CapabilityPickerLayout.ServiceBundles] {
        layout.serviceBundles.filter { selection.contains($0.providerId) }
    }

    /// The primary button only needs a provider selection — bundle toggles
    /// never disable it. An all-off service is a valid submission: the view
    /// model revokes the agent's existing grant for it (Done-as-revoke) or
    /// treats it as a decline-style no-op, and an empty bundle set never
    /// reaches the grant writer either way.
    private var approveEnabled: Bool {
        !selection.isEmpty
    }

    /// The bundle toggle state pruned to the services the approval covers.
    /// Empty sets pass through deliberately — they are the view model's
    /// revoke/no-op signal for that service.
    private var approvedBundleSelection: [String: Set<String>] {
        var approved: [String: Set<String>] = [:]
        for group in selectedBundleGroups {
            approved[group.serviceId] = enabledBundleIds[group.serviceId] ?? []
        }
        return approved
    }

    /// True when approving will run a connect step (OS prompt / OAuth) first.
    /// A selected-but-unlinked provider whose toggles are all off doesn't
    /// count: the tap grants it nothing, so there is nothing to connect for
    /// and the button honestly reads "Done".
    private var needsConnect: Bool {
        layout.providers.contains { provider in
            guard selection.contains(provider.id), !provider.linked else { return false }
            guard let group = layout.serviceBundles.first(where: { $0.providerId == provider.id }) else {
                return true
            }
            return !(enabledBundleIds[group.serviceId] ?? []).isEmpty
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            if let provider = singleProvider {
                serviceIcon(provider, size: Constant.headerIconSize, cornerRadius: DesignConstants.CornerRadius.medium)
            }

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("\(agentName ?? "Agent") can use your")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                Text(headerTitle)
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var headerTitle: String {
        if let provider = singleProvider {
            return provider.displayName
        }
        return layout.request.subject.subjectNounPhrase.localizedCapitalized
    }

    @ViewBuilder
    private func serviceIcon(
        _ provider: CapabilityPickerLayout.ProviderSummary,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        if let assetName = ConnectionServiceIcon.assetName(forServiceId: provider.id.cloudServiceId) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.colorBorderEdge, lineWidth: Constant.iconBorderWidth)
                )
        } else {
            Image(systemName: provider.iconName.isEmpty ? "link" : provider.iconName)
                .font(size >= Constant.headerIconSize ? .title : .body)
                .foregroundStyle(.colorTextPrimary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.colorFillMinimal)
                )
        }
    }

    // MARK: - Provider chooser (multi-candidate layouts only)

    private var providerSection: some View {
        VStack(spacing: Constant.rowGap) {
            ForEach(selectableProviders, id: \.id) { provider in
                providerRow(provider)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
    }

    private func providerRow(_ provider: CapabilityPickerLayout.ProviderSummary) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            serviceIcon(provider, size: Constant.rowIconSize, cornerRadius: DesignConstants.CornerRadius.small)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(provider.displayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                if !provider.linked {
                    Text("Not connected")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            Spacer(minLength: 0)
            if selection.contains(provider.id) {
                Image(systemName: "checkmark")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorBackgroundSurfaceless)
        .contentShape(.rect)
        .onTapGesture { select(provider) }
        .accessibilityAddTraits(selection.contains(provider.id) ? [.isSelected] : [])
    }

    private func select(_ provider: CapabilityPickerLayout.ProviderSummary) {
        if allowsMultipleSelection {
            if selection.contains(provider.id) {
                selection.remove(provider.id)
            } else {
                selection.insert(provider.id)
            }
        } else {
            selection = [provider.id]
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Permissions requested")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)

            VStack(spacing: Constant.rowGap) {
                ForEach(selectedBundleGroups, id: \.serviceId) { group in
                    ForEach(group.rows, id: \.id) { row in
                        permissionRow(row, serviceId: group.serviceId)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        }
    }

    private func permissionRow(
        _ row: CapabilityPickerLayout.ServiceBundles.Row,
        serviceId: String
    ) -> some View {
        let binding: Binding<Bool> = bundleBinding(serviceId: serviceId, bundleId: row.id)
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

    private func bundleBinding(serviceId: String, bundleId: String) -> Binding<Bool> {
        Binding(
            get: { enabledBundleIds[serviceId, default: []].contains(bundleId) },
            set: { isOn in
                var ids = enabledBundleIds[serviceId, default: []]
                if isOn {
                    ids.insert(bundleId)
                } else {
                    ids.remove(bundleId)
                }
                enabledBundleIds[serviceId] = ids
            }
        )
    }

    // MARK: - Primary button

    private var approveButton: some View {
        let approveAction: () -> Void = {
            onApprove(selection, approvedBundleSelection)
        }
        // "Connect" tells the user an OAuth / OS-permission step comes first;
        // "Done" is the Figma label for the grant-only confirmation.
        return Button(needsConnect ? "Connect" : "Done", action: approveAction)
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(!approveEnabled)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private enum Constant {
        static let headerIconSize: CGFloat = 56.0
        static let rowIconSize: CGFloat = 24.0
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
private func previewBundles(
    providerId: String = "composio.googlecalendar",
    grantedBundleIds: Set<String>? = nil
) -> [CapabilityPickerLayout.ServiceBundles] {
    [
        CapabilityPickerLayout.ServiceBundles(
            providerId: ProviderID(rawValue: providerId),
            serviceId: "googlecalendar",
            serviceVersion: 5,
            rows: [
                .init(
                    id: "calendar.events",
                    title: "Events",
                    description: "View and edit events on all calendars",
                    defaultEnabled: false
                ),
            ],
            grantedBundleIds: grantedBundleIds
        ),
    ]
}

private func previewProvider(
    id: String = "composio.googlecalendar",
    displayName: String = "Google Calendar",
    linked: Bool
) -> CapabilityPickerLayout.ProviderSummary {
    CapabilityPickerLayout.ProviderSummary(
        id: ProviderID(rawValue: id),
        displayName: displayName,
        iconName: "calendar",
        subject: .calendar,
        linked: linked,
        supportsCapability: true
    )
}

private func previewRequest() -> CapabilityRequest {
    CapabilityRequest(
        requestId: "preview-1",
        askerInboxId: "preview-asker",
        subject: .calendar,
        capability: .read,
        rationale: "To book that meeting"
    )
}

#Preview("Connected — confirm (Google Calendar)") {
    CapabilityApprovalSheetView(
        layout: CapabilityPickerLayout(
            request: previewRequest(),
            variant: .confirm,
            providers: [previewProvider(linked: true)],
            defaultSelection: [ProviderID(rawValue: "composio.googlecalendar")],
            serviceBundles: previewBundles()
        ),
        agentName: "Assistant",
        onApprove: { _, _ in }
    )
}

#Preview("Pre-connect — connectAndApprove (Google Calendar)") {
    CapabilityApprovalSheetView(
        layout: CapabilityPickerLayout(
            request: previewRequest(),
            variant: .connectAndApprove,
            providers: [previewProvider(linked: false)],
            defaultSelection: [],
            serviceBundles: previewBundles()
        ),
        agentName: "Assistant",
        onApprove: { _, _ in }
    )
}

#Preview("Existing grant — uncheck to revoke") {
    CapabilityApprovalSheetView(
        layout: CapabilityPickerLayout(
            request: previewRequest(),
            variant: .confirm,
            providers: [previewProvider(linked: true)],
            defaultSelection: [ProviderID(rawValue: "composio.googlecalendar")],
            serviceBundles: previewBundles(grantedBundleIds: ["calendar.events"])
        ),
        agentName: "Assistant",
        onApprove: { _, _ in }
    )
}

#Preview("Catalog outage — no bundle rows") {
    CapabilityApprovalSheetView(
        layout: CapabilityPickerLayout(
            request: previewRequest(),
            variant: .confirm,
            providers: [previewProvider(linked: true)],
            defaultSelection: [ProviderID(rawValue: "composio.googlecalendar")]
        ),
        agentName: "Assistant",
        onApprove: { _, _ in }
    )
}

#Preview("Multi-candidate — provider chooser") {
    CapabilityApprovalSheetView(
        layout: CapabilityPickerLayout(
            request: previewRequest(),
            variant: .singleSelect,
            providers: [
                previewProvider(linked: true),
                previewProvider(
                    id: "composio.microsoftoutlook",
                    displayName: "Microsoft Outlook",
                    linked: false
                ),
            ],
            defaultSelection: [ProviderID(rawValue: "composio.googlecalendar")],
            serviceBundles: previewBundles()
        ),
        agentName: "Assistant",
        onApprove: { _, _ in }
    )
}
#endif
