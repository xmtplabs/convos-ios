import ConvosConnections
import ConvosCore
import SwiftUI

/// Top-level capability-request card. Renders one of five visual variants
/// (`Variant 1 / 2a / 2b / 3 / verb-consent`) based on the `CapabilityPickerLayout` it
/// receives from `CapabilityRequestHandler.computeLayout`.
///
/// Stateless w.r.t. the resolver — the parent passes `onApprove` / `onDeny` / `onConnect`
/// closures and decides where to wire them. This keeps every preview below renderable
/// without booting an XMTP client or a GRDB resolver.
struct CapabilityPickerCardView: View {
    let layout: CapabilityPickerLayout
    let onApprove: (Set<ProviderID>) -> Void
    let onDeny: () -> Void
    let onConnect: (ProviderID) -> Void

    @State private var selection: Set<ProviderID>

    init(
        layout: CapabilityPickerLayout,
        onApprove: @escaping (Set<ProviderID>) -> Void,
        onDeny: @escaping () -> Void,
        onConnect: @escaping (ProviderID) -> Void
    ) {
        self.layout = layout
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onConnect = onConnect
        _selection = State(initialValue: layout.defaultSelection)
    }

    var body: some View {
        cardContent
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, DesignConstants.Spacing.step5x)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
            )
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            // `@State` initialValue runs once per view identity. If the parent passes a
            // new layout (e.g. a fresh `capability_request` arrives) while SwiftUI keeps
            // this view alive, sync the seed selection across so we don't show stale rows
            // checked.
            .onChange(of: layout.defaultSelection) { _, newValue in
                selection = newValue
            }
    }

    @ViewBuilder
    private var cardContent: some View {
        switch layout.variant {
        case .confirm:
            confirmCard
        case .singleSelect:
            singleSelectCard
        case .multiSelect:
            multiSelectCard
        case .connectAndApprove:
            connectAndApproveCard
        case .verbConsent:
            verbConsentCard
        }
    }

    // MARK: - Variant 1 — single linked, default-approve

    @ViewBuilder
    private var confirmCard: some View {
        let onlyProvider = layout.providers.first { layout.defaultSelection.contains($0.id) }
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            header
            if let onlyProvider {
                providerRow(onlyProvider, style: .checkmark(checked: true))
            }
            actionButtons(approveEnabled: !selection.isEmpty)
        }
    }

    // MARK: - Variant 2a — single-select picker

    @ViewBuilder
    private var singleSelectCard: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            header
            VStack(spacing: DesignConstants.Spacing.stepX) {
                ForEach(layout.providers, id: \.id) { provider in
                    providerRow(provider, style: rowStyle(forSingleSelect: provider))
                        .contentShape(.rect)
                        .onTapGesture { selectSingle(provider) }
                }
            }
            actionButtons(approveEnabled: !selection.isEmpty)
        }
    }

    // MARK: - Variant 2b — multi-select picker (federating subject + read)

    @ViewBuilder
    private var multiSelectCard: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            header
            VStack(spacing: DesignConstants.Spacing.stepX) {
                ForEach(layout.providers, id: \.id) { provider in
                    providerRow(provider, style: rowStyle(forMultiSelect: provider))
                        .contentShape(.rect)
                        .onTapGesture { toggleMulti(provider) }
                }
            }
            actionButtons(approveEnabled: !selection.isEmpty)
        }
    }

    // MARK: - Variant 3 — zero linked, connect-and-approve

    @ViewBuilder
    private var connectAndApproveCard: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            header

            VStack(spacing: DesignConstants.Spacing.stepX) {
                ForEach(layout.providers, id: \.id) { provider in
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        providerIcon(provider)
                        Text(provider.displayName)
                            .font(.body)
                            .foregroundStyle(.colorTextPrimary)
                        Spacer(minLength: 0)
                        Button("Connect") {
                            onConnect(provider.id)
                        }
                        .convosButtonStyle(.outlineCapsule(fullWidth: false))
                    }
                    .padding(DesignConstants.Spacing.step2x)
                }
            }

            Button("Deny", action: onDeny)
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Verb-consent — short-circuit, single provider known

    @ViewBuilder
    private var verbConsentCard: some View {
        let onlyProvider = layout.providers.first { layout.defaultSelection.contains($0.id) }
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                if let onlyProvider {
                    providerIcon(onlyProvider)
                }
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(verbConsentTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    if !layout.request.rationale.isEmpty {
                        Text(layout.request.rationale)
                            .font(.footnote)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            actionButtons(approveEnabled: !selection.isEmpty)
        }
    }

    // MARK: - Shared header / rows / buttons

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(headerTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            if !layout.request.rationale.isEmpty {
                Text(layout.request.rationale)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
    }

    private var headerTitle: String {
        let action = verbDisplayPhrase
        return "Assistant wants to \(action) your \(headerNoun)"
    }

    private var headerNoun: String {
        let eligible = layout.providers.filter(\.supportsCapability)
        if eligible.count == 1, let only = eligible.first, let custom = only.subjectNounPhrase {
            return custom
        }
        return layout.request.subject.subjectNounPhrase
    }

    private var verbConsentTitle: String {
        let action = verbDisplayPhrase
        let provider = layout.providers.first { layout.defaultSelection.contains($0.id) }
        let providerName = provider?.displayName ?? "this provider"
        let noun = provider?.subjectNounPhrase ?? layout.request.subject.subjectNounPhrase
        return "Allow \(providerName) to \(action) \(noun)?"
    }

    private var verbDisplayPhrase: String {
        switch layout.request.capability {
        case .read: return "read"
        case .writeCreate: return "create entries in"
        case .writeUpdate: return "update entries in"
        case .writeDelete: return "delete entries in"
        }
    }

    private enum RowStyle {
        case checkmark(checked: Bool)
        case radio(selected: Bool)
        case checkbox(checked: Bool)
    }

    private func rowStyle(forSingleSelect provider: CapabilityPickerLayout.ProviderSummary) -> RowStyle {
        .radio(selected: selection.contains(provider.id))
    }

    private func rowStyle(forMultiSelect provider: CapabilityPickerLayout.ProviderSummary) -> RowStyle {
        .checkbox(checked: selection.contains(provider.id))
    }

    @ViewBuilder
    private func providerRow(
        _ provider: CapabilityPickerLayout.ProviderSummary,
        style: RowStyle
    ) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            providerIcon(provider)
            VStack(alignment: .leading, spacing: 0) {
                Text(provider.displayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                if !provider.linked {
                    Text("Tap to connect")
                        .font(.caption2)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            Spacer(minLength: 0)
            rowAccessory(style: style)
        }
        .padding(DesignConstants.Spacing.step2x)
    }

    @ViewBuilder
    private func providerIcon(_ provider: CapabilityPickerLayout.ProviderSummary) -> some View {
        Image(systemName: provider.iconName.isEmpty ? "link" : provider.iconName)
            .font(.title3)
            .foregroundStyle(.colorTextPrimary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(Color.colorBackgroundSurfaceless)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                            .stroke(Color.colorBorderSubtle, lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    private func rowAccessory(style: RowStyle) -> some View {
        switch style {
        case .checkmark(let checked):
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? Color.colorFillPrimary : .colorTextSecondary)
        case .radio(let selected):
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.colorFillPrimary : .colorTextSecondary)
        case .checkbox(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.colorFillPrimary : .colorTextSecondary)
        }
    }

    private func selectSingle(_ provider: CapabilityPickerLayout.ProviderSummary) {
        if !provider.linked {
            onConnect(provider.id)
            return
        }
        selection = [provider.id]
    }

    private func toggleMulti(_ provider: CapabilityPickerLayout.ProviderSummary) {
        if !provider.linked {
            onConnect(provider.id)
            return
        }
        if selection.contains(provider.id) {
            selection.remove(provider.id)
        } else {
            selection.insert(provider.id)
        }
    }

    @ViewBuilder
    private func actionButtons(approveEnabled: Bool) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Button("Deny", action: onDeny)
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)

            Button("Approve") {
                onApprove(selection)
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(!approveEnabled)
        }
    }
}

// MARK: - Previews

#if DEBUG
private extension CapabilityPickerLayout.ProviderSummary {
    static func sample(
        id: String,
        displayName: String,
        iconName: String,
        subject: CapabilitySubject,
        linked: Bool = true
    ) -> CapabilityPickerLayout.ProviderSummary {
        CapabilityPickerLayout.ProviderSummary(
            id: ProviderID(rawValue: id),
            displayName: displayName,
            iconName: iconName,
            subject: subject,
            linked: linked,
            supportsCapability: true
        )
    }
}

private extension CapabilityRequest {
    static func sample(
        subject: CapabilitySubject = .calendar,
        capability: ConnectionCapability = .read,
        rationale: String = "To summarize your week"
    ) -> CapabilityRequest {
        CapabilityRequest(
            requestId: "preview-1",
            subject: subject,
            capability: capability,
            rationale: rationale
        )
    }
}

private struct PreviewBackground<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack {
            content()
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity)
        .background(Color.colorBackgroundRaisedSecondary)
    }
}

#Preview("Variant 1 — single linked (Apple Calendar)") {
    PreviewBackground {
        CapabilityPickerCardView(
            layout: CapabilityPickerLayout(
                request: .sample(),
                variant: .confirm,
                providers: [.sample(id: "device.calendar", displayName: "Apple Calendar", iconName: "calendar", subject: .calendar)],
                defaultSelection: [ProviderID(rawValue: "device.calendar")]
            ),
            onApprove: { _ in },
            onDeny: {},
            onConnect: { _ in }
        )
    }
}

#Preview("Variant 2a — single-select (calendar, read)") {
    PreviewBackground {
        CapabilityPickerCardView(
            layout: CapabilityPickerLayout(
                request: .sample(),
                variant: .singleSelect,
                providers: [
                    .sample(id: "composio.google_calendar", displayName: "Google Calendar", iconName: "calendar", subject: .calendar),
                    .sample(id: "composio.microsoft_outlook", displayName: "Microsoft Outlook", iconName: "calendar", subject: .calendar),
                    .sample(id: "device.calendar", displayName: "Apple Calendar", iconName: "calendar", subject: .calendar),
                ],
                defaultSelection: [ProviderID(rawValue: "device.calendar")]
            ),
            onApprove: { _ in },
            onDeny: {},
            onConnect: { _ in }
        )
    }
}

#Preview("Variant 2a — single-select (write verb on .fitness)") {
    PreviewBackground {
        CapabilityPickerCardView(
            layout: CapabilityPickerLayout(
                request: .sample(subject: .fitness, capability: .writeCreate, rationale: "Log a workout"),
                variant: .singleSelect,
                providers: [
                    .sample(id: "composio.fitbit", displayName: "Fitbit", iconName: "figure.run", subject: .fitness),
                    .sample(id: "composio.strava", displayName: "Strava", iconName: "figure.run", subject: .fitness),
                ],
                defaultSelection: []
            ),
            onApprove: { _ in },
            onDeny: {},
            onConnect: { _ in }
        )
    }
}

#Preview("Variant 2b — multi-select (fitness reads)") {
    PreviewBackground {
        CapabilityPickerCardView(
            layout: CapabilityPickerLayout(
                request: .sample(subject: .fitness, capability: .read, rationale: "To summarize your training week"),
                variant: .multiSelect,
                providers: [
                    .sample(id: "composio.fitbit", displayName: "Fitbit", iconName: "figure.run", subject: .fitness),
                    .sample(id: "composio.strava", displayName: "Strava", iconName: "figure.run", subject: .fitness),
                    .sample(id: "device.health", displayName: "Apple Health", iconName: "heart.text.square", subject: .fitness, linked: false),
                ],
                defaultSelection: [
                    ProviderID(rawValue: "composio.fitbit"),
                    ProviderID(rawValue: "composio.strava"),
                ]
            ),
            onApprove: { _ in },
            onDeny: {},
            onConnect: { _ in }
        )
    }
}

#Preview("Variant 3 — zero linked (connect-and-approve)") {
    PreviewBackground {
        CapabilityPickerCardView(
            layout: CapabilityPickerLayout(
                request: .sample(),
                variant: .connectAndApprove,
                providers: [
                    .sample(id: "device.calendar", displayName: "Apple Calendar", iconName: "calendar", subject: .calendar, linked: false),
                    .sample(id: "composio.google_calendar", displayName: "Google Calendar", iconName: "calendar", subject: .calendar, linked: false),
                ],
                defaultSelection: []
            ),
            onApprove: { _ in },
            onDeny: {},
            onConnect: { _ in }
        )
    }
}

#Preview("Verb-consent — second verb on Apple Calendar") {
    PreviewBackground {
        CapabilityPickerCardView(
            layout: CapabilityPickerLayout(
                request: .sample(subject: .calendar, capability: .writeCreate, rationale: "Add tomorrow's standup"),
                variant: .verbConsent,
                providers: [.sample(id: "device.calendar", displayName: "Apple Calendar", iconName: "calendar", subject: .calendar)],
                defaultSelection: [ProviderID(rawValue: "device.calendar")]
            ),
            onApprove: { _ in },
            onDeny: {},
            onConnect: { _ in }
        )
    }
}
#endif
