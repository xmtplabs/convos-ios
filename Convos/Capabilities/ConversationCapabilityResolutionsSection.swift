import Combine
import ConvosConnections
import ConvosCore
import SwiftUI

struct ResolvedCapabilityRow: Identifiable, Hashable {
    let id: String
    let provider: ResolvedProvider
    let subject: CapabilitySubject
    let capabilities: [ConnectionCapability]
}

struct ResolvedProvider: Hashable {
    let id: ProviderID
    let displayName: String
    let iconName: String
}

@MainActor @Observable
final class ConversationCapabilityResolutionsViewModel {
    private(set) var rows: [ResolvedCapabilityRow] = []

    private let conversationId: String
    private let session: any SessionManagerProtocol
    private var resolutionsCancellable: AnyCancellable?
    private var latestResolutions: [CapabilityResolution] = []

    init(conversationId: String, session: any SessionManagerProtocol) {
        self.conversationId = conversationId
        self.session = session

        resolutionsCancellable = session.capabilityResolutionsRepository(for: conversationId)
            .resolutionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resolutions in
                self?.latestResolutions = resolutions
                self?.recomputeRows()
            }

        // Provider rename / linked-state changes don't affect which (subject, capability)
        // rows exist, but they do affect the displayName + icon we render. Re-render the
        // current resolutions whenever the registry ticks. The task captures self weakly
        // so it exits naturally on the next yield once the view model is deallocated.
        let registry = session.capabilityProviderRegistry()
        Task { [weak self] in
            for await _ in registry.providerChanges {
                guard let self else { return }
                await MainActor.run { [weak self] in
                    self?.recomputeRows()
                }
            }
        }
    }

    var hasResolutions: Bool { !rows.isEmpty }

    private func recomputeRows() {
        let resolutions = latestResolutions
        let registry = session.capabilityProviderRegistry()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rows = await Self.buildRows(from: resolutions, registry: registry)
        }
    }

    private static func buildRows(
        from resolutions: [CapabilityResolution],
        registry: any CapabilityProviderRegistry
    ) async -> [ResolvedCapabilityRow] {
        var grouped: [GroupKey: [ConnectionCapability]] = [:]
        for resolution in resolutions {
            for providerId in resolution.providerIds {
                let key = GroupKey(providerId: providerId, subject: resolution.subject)
                grouped[key, default: []].append(resolution.capability)
            }
        }

        var rows: [ResolvedCapabilityRow] = []
        for (key, verbs) in grouped {
            let provider = await resolveProviderInfo(
                id: key.providerId,
                subject: key.subject,
                registry: registry
            )
            rows.append(
                ResolvedCapabilityRow(
                    id: "\(key.providerId.rawValue)|\(key.subject.rawValue)",
                    provider: provider,
                    subject: key.subject,
                    capabilities: verbs.sorted(by: { $0.rawValue < $1.rawValue })
                )
            )
        }
        return rows
            .filter { !isDeviceProvider($0.provider.id) }
            .sorted { lhs, rhs in
                if lhs.provider.displayName == rhs.provider.displayName {
                    return lhs.subject.rawValue < rhs.subject.rawValue
                }
                return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
            }
    }

    private static func isDeviceProvider(_ id: ProviderID) -> Bool {
        ConnectionKind.fromDeviceProviderId(id) != nil
    }

    private static func resolveProviderInfo(
        id: ProviderID,
        subject: CapabilitySubject,
        registry: any CapabilityProviderRegistry
    ) async -> ResolvedProvider {
        let providers = await registry.providers(for: subject)
        if let match = providers.first(where: { $0.id == id }) {
            return ResolvedProvider(
                id: id,
                displayName: match.displayName,
                iconName: match.iconName
            )
        }
        // Fallback for providers no longer in the registry (e.g. cloud connection removed
        // before this conversation was opened). Pull display info from the static device
        // catalog so the row still renders something readable.
        if let spec = DeviceCapabilityProvider.defaultSpecs.first(where: { $0.id == id }) {
            return ResolvedProvider(id: id, displayName: spec.displayName, iconName: spec.iconName)
        }
        return ResolvedProvider(id: id, displayName: id.rawValue, iconName: "link")
    }

    private struct GroupKey: Hashable {
        let providerId: ProviderID
        let subject: CapabilitySubject
    }
}

struct ConversationCapabilityResolutionsSection: View {
    @Bindable var viewModel: ConversationCapabilityResolutionsViewModel

    var body: some View {
        Section {
            ForEach(viewModel.rows) { row in
                FeatureRowItem(
                    imageName: nil,
                    symbolName: row.provider.iconName,
                    title: row.provider.displayName,
                    subtitle: subtitle(for: row),
                    iconBackgroundColor: .colorBackgroundSurfaceless,
                    iconForegroundColor: .colorTextPrimary
                ) {
                    EmptyView()
                }
            }
        } header: {
            Text("Connections")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private func subtitle(for row: ResolvedCapabilityRow) -> String {
        let verbList = row.capabilities.map(verbDisplayName).joined(separator: ", ")
        return "\(row.subject.displayName) · \(verbList)"
    }

    private func verbDisplayName(_ capability: ConnectionCapability) -> String {
        switch capability {
        case .read: return "Read"
        case .writeCreate: return "Create"
        case .writeUpdate: return "Update"
        case .writeDelete: return "Delete"
        }
    }
}
