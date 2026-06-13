import ConvosConnections
import SwiftUI
import UIKit

struct RootConnectionsView: View {
    @Bindable var model: ExampleModel

    var body: some View {
        List {
            ForEach(model.kinds, id: \.self) { kind in
                Section {
                    AuthorizationRow(
                        kind: kind,
                        status: model.statuses[kind] ?? .notDetermined,
                        onAttemptEnable: {
                            Task { await model.requestAuthorization(for: kind) }
                        },
                        onAttemptDisable: {
                            Self.openAppSettings()
                            Task { await model.refresh() }
                        }
                    )

                    ForEach(model.conversations(for: kind)) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isEnabled: model.enabledConversationIds.contains(conversation.id),
                            messageCount: model.messagesByConversation[conversation.id]?.count ?? 0,
                            onToggle: { newValue in
                                Task { await model.toggle(conversation: conversation, enabled: newValue) }
                            }
                        )
                    }
                }
            }

            Section {
                Text(Self.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = model.lastError {
                Section("Last error") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("ConvosConnections")
        .refreshable { await model.refresh() }
    }

    private static func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private static let explanation: String = """
        Authorization is one toggle per connection at the iOS level — granting Health covers \
        every conversation. Enablement is the per-conversation toggle — turn Health on for \
        "Fitness coach" without turning it on for "Sleep coach." That split is the package's \
        main value.
        """
}

private struct AuthorizationRow: View {
    let kind: ConnectionKind
    let status: ConnectionAuthorizationStatus
    let onAttemptEnable: () -> Void
    let onAttemptDisable: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImageName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.body.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { Self.isAuthorized(status) },
                    set: { newValue in
                        if newValue {
                            onAttemptEnable()
                        } else {
                            onAttemptDisable()
                        }
                    }
                )
            )
            .labelsHidden()
            .disabled(status == .unavailable)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch status {
        case .notDetermined: return "Not authorized — toggle to grant"
        case .authorized: return "Authorized at iOS level"
        case .denied: return "Denied in Settings"
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

    private static func isAuthorized(_ status: ConnectionAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .partial: return true
        case .notDetermined, .denied, .unavailable: return false
        }
    }
}

private struct ConversationRow: View {
    let conversation: MockConversation
    let isEnabled: Bool
    let messageCount: Int
    let onToggle: (Bool) -> Void

    var body: some View {
        NavigationLink(value: conversation) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.name)
                        .font(.callout)
                    Text(conversation.id)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if messageCount > 0 {
                    Text("\(messageCount)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in onToggle(newValue) }
                    )
                )
                .labelsHidden()
            }
        }
    }
}
