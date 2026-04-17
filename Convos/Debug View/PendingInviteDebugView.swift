import ConvosCore
import SwiftUI

struct PendingInviteDebugView: View {
    let session: any SessionManagerProtocol
    @State private var details: [PendingInviteDetail] = []
    @State private var loadError: String?
    @State private var isDeleting: Bool = false

    private var expiredDetails: [PendingInviteDetail] {
        let cutoff = Date().addingTimeInterval(-SessionManager.stalePendingInviteInterval)
        return details.filter { $0.createdAt < cutoff }
    }

    private var deletableDetails: [PendingInviteDetail] {
        expiredDetails.filter { $0.memberCount <= 1 }
    }

    private var stuckDetails: [PendingInviteDetail] {
        expiredDetails.filter { $0.hasOtherConversations }
    }

    private var activeDetails: [PendingInviteDetail] {
        let cutoff = Date().addingTimeInterval(-SessionManager.stalePendingInviteInterval)
        return details.filter { $0.createdAt >= cutoff }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total")
                    Spacer()
                    Text("\(details.count)")
                        .foregroundStyle(.colorTextSecondary)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Active")
                    Spacer()
                    Text("\(activeDetails.count)")
                        .foregroundStyle(.colorTextSecondary)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Expired (> 24 hours)")
                    Spacer()
                    Text("\(expiredDetails.count)")
                        .foregroundStyle(expiredDetails.isEmpty ? .colorTextSecondary : .red)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Deletable (expired, ≤ 1 member)")
                    Spacer()
                    Text("\(deletableDetails.count)")
                        .foregroundStyle(deletableDetails.isEmpty ? .colorTextSecondary : .red)
                        .font(.system(.body, design: .monospaced))
                }
                if !stuckDetails.isEmpty {
                    HStack {
                        Text("⚠️ Stuck (has other convos)")
                        Spacer()
                        Text("\(stuckDetails.count)")
                            .foregroundStyle(.orange)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            } header: {
                Text("Summary")
            }

            if let loadError {
                Section {
                    Text(loadError)
                        .foregroundStyle(.red)
                }
            }

            if details.isEmpty && loadError == nil {
                Section {
                    Text("No pending invites found")
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            if !expiredDetails.isEmpty {
                Section {
                    ForEach(expiredDetails) { detail in
                        inviteRow(detail: detail)
                    }
                } header: {
                    Label("Expired", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if !activeDetails.isEmpty {
                Section {
                    ForEach(activeDetails) { detail in
                        inviteRow(detail: detail)
                    }
                } header: {
                    Text("Active")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !deletableDetails.isEmpty {
                deleteExpiredButton
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .padding(.bottom, DesignConstants.Spacing.step2x)
            }
        }
        .navigationTitle("Pending Invites")
        .toolbarTitleDisplayMode(.inline)
        .task {
            loadDetails()
        }
        .refreshable {
            loadDetails()
        }
    }

    private var deleteExpiredButton: some View {
        Button {
            deleteExpired()
        } label: {
            ZStack {
                Text("Hold to delete expired")
                    .opacity(isDeleting ? 0 : 1)
                Text("Deleting...")
                    .opacity(isDeleting ? 1 : 0)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .disabled(isDeleting)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: {
            var config = HoldToConfirmStyleConfig.default
            config.duration = 3.0
            config.backgroundColor = .colorCaution
            return config
        }()))
    }

    private func deleteExpired() {
        isDeleting = true
        Task {
            do {
                let count = try await session.deleteExpiredPendingInvites()
                Log.info("Deleted \(count) expired pending invite(s)")
            } catch {
                Log.error("Failed to delete expired pending invites: \(error)")
            }
            loadDetails()
            isDeleting = false
        }
    }

    private func inviteRow(detail: PendingInviteDetail) -> some View {
        let isExpired = expiredDetails.contains(detail)
        let isStuck = isExpired && detail.hasOtherConversations

        return VStack(alignment: .leading, spacing: 6) {
            Text(detail.conversationName ?? "Unnamed")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.colorTextPrimary)

            if isStuck {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Inbox has other conversations - may indicate a bug")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)

                    ForEach(detail.otherConversations) { other in
                        otherConversationRow(other)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            labeledValue("Waiting", waitingDuration(since: detail.createdAt))
            labeledValue("Created", detail.createdAt.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            labeledValue("Client ID", detail.clientId, monospaced: true)
            labeledValue("Inbox ID", detail.inboxId, monospaced: true)
            labeledValue("Members", "\(detail.memberCount)")
            labeledValue("Invite Tag", String(detail.inviteTag.prefix(16)) + "…", monospaced: true)
        }
        .padding(.vertical, 4)
    }

    private func otherConversationRow(_ info: OtherConversationInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(EmojiSelector.emoji(for: info.clientConversationId))
                Text(info.name ?? "Unnamed")
                    .font(.caption.weight(.medium))
            }
            Text(info.conversationId)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.colorTextTertiary)
        }
        .padding(.leading, 8)
    }

    private func labeledValue(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.colorTextTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.colorTextSecondary)
                .textSelection(.enabled)
        }
    }

    private func loadDetails() {
        do {
            details = try session.pendingInviteDetails()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func waitingDuration(since date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)d \(remainingHours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

#Preview {
    NavigationStack {
        PendingInviteDebugView(session: MockInboxesService())
    }
}
