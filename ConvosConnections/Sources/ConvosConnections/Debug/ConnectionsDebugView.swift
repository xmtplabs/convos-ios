import Foundation
#if canImport(SwiftUI)
import SwiftUI

/// A SwiftUI inspector for the connections system. Shows every available source, its
/// authorization status, the conversations it's enabled in, and a live log of emitted
/// payloads with their fan-out targets.
///
/// Host apps surface this from a debug menu. The view owns no persistence of its own —
/// it reads from and writes to the `ConnectionsManager` it is initialized with.
public struct ConnectionsDebugView: View {
    @State private var model: DebugModel

    public init(manager: ConnectionsManager, sampleConversationIds: [String] = []) {
        _model = State(initialValue: DebugModel(manager: manager, sampleConversationIds: sampleConversationIds))
    }

    public var body: some View {
        List {
            Section("Connections") {
                ForEach(model.kinds, id: \.self) { kind in
                    ConnectionRow(
                        kind: kind,
                        status: model.statuses[kind] ?? .notDetermined,
                        enabledConversationIds: model.enabledByKind[kind] ?? [],
                        sampleConversationIds: model.sampleConversationIds,
                        onRequestAuth: { Task { await model.requestAuthorization(kind: kind) } },
                        onToggleConversation: { conversationId, enabled in
                            Task { await model.setEnabled(enabled, kind: kind, conversationId: conversationId) }
                        }
                    )
                }
            }

            Section("Recent payloads (\(model.recentPayloads.count))") {
                if model.recentPayloads.isEmpty {
                    Text("No payloads delivered yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentPayloads.reversed()) { record in
                        RecentPayloadRow(record: record)
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
            }
        }
    }
}

private struct ConnectionRow: View {
    let kind: ConnectionKind
    let status: ConnectionAuthorizationStatus
    let enabledConversationIds: [String]
    let sampleConversationIds: [String]
    let onRequestAuth: () -> Void
    let onToggleConversation: (String, Bool) -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if case .notDetermined = status {
                    Button("Request Authorization", action: onRequestAuth)
                        .buttonStyle(.borderedProminent)
                }
                if sampleConversationIds.isEmpty {
                    Text("Pass sample conversation ids to `ConnectionsDebugView(manager:sampleConversationIds:)` to toggle enablement here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sampleConversationIds, id: \.self) { conversationId in
                        Toggle(
                            conversationId,
                            isOn: Binding(
                                get: { enabledConversationIds.contains(conversationId) },
                                set: { newValue in onToggleConversation(conversationId, newValue) }
                            )
                        )
                        .font(.callout)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: kind.systemImageName)
                    .frame(width: 24)
                VStack(alignment: .leading) {
                    Text(kind.displayName)
                        .font(.body)
                    Text(statusDescription)
                        .font(.footnote)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if !enabledConversationIds.isEmpty {
                    Text("\(enabledConversationIds.count)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var statusDescription: String {
        switch status {
        case .notDetermined: return "Not yet requested"
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .partial(let missing): return "Partial (\(missing.count) missing)"
        case .unavailable: return "Unavailable on this device"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized: return .green
        case .partial: return .orange
        case .denied, .unavailable: return .red
        case .notDetermined: return .secondary
        }
    }
}

private struct RecentPayloadRow: View {
    let record: RecordedPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.payload.source.displayName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(record.receivedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.payload.summary)
                .font(.footnote)
            if record.fanOutConversationIds.isEmpty {
                Text("No conversations enabled — payload was recorded but not delivered.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Delivered to: \(record.fanOutConversationIds.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
@Observable
private final class DebugModel {
    let manager: ConnectionsManager
    let sampleConversationIds: [String]
    private(set) var kinds: [ConnectionKind] = []
    private(set) var statuses: [ConnectionKind: ConnectionAuthorizationStatus] = [:]
    private(set) var enabledByKind: [ConnectionKind: [String]] = [:]
    private(set) var recentPayloads: [RecordedPayload] = []

    init(manager: ConnectionsManager, sampleConversationIds: [String]) {
        self.manager = manager
        self.sampleConversationIds = sampleConversationIds
    }

    func refresh() async {
        let kinds = manager.availableKinds()
        self.kinds = kinds
        var statuses: [ConnectionKind: ConnectionAuthorizationStatus] = [:]
        var enabled: [ConnectionKind: [String]] = [:]
        for kind in kinds {
            statuses[kind] = await manager.authorizationStatus(for: kind)
            enabled[kind] = await manager.enabledConversationIds(for: kind)
        }
        self.statuses = statuses
        self.enabledByKind = enabled
        self.recentPayloads = await manager.recentPayloadLog()
    }

    func requestAuthorization(kind: ConnectionKind) async {
        do {
            _ = try await manager.requestAuthorization(for: kind)
        } catch {
            // surface in UI in a follow-up; for now just refresh
        }
        await refresh()
    }

    func setEnabled(_ enabled: Bool, kind: ConnectionKind, conversationId: String) async {
        await manager.setEnabled(enabled, kind: kind, conversationId: conversationId)
        if enabled {
            try? await manager.startSource(kind: kind)
        }
        await refresh()
    }
}
#endif
