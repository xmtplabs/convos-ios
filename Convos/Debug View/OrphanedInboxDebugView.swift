import ConvosCore
import SwiftUI

struct OrphanedInboxDebugView: View {
    let session: any SessionManagerProtocol
    @State private var orphans: [OrphanedInboxDetail] = []
    @State private var loadError: String?
    @State private var deletingClientId: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total")
                    Spacer()
                    Text("\(orphans.count)")
                        .foregroundStyle(orphans.isEmpty ? .colorTextSecondary : .red)
                        .font(.system(.body, design: .monospaced))
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

            if orphans.isEmpty && loadError == nil {
                Section {
                    Text("No orphaned inboxes found")
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            ForEach(orphans) { orphan in
                Section {
                    orphanRow(orphan: orphan)

                    Button {
                        deleteOrphan(orphan)
                    } label: {
                        HStack {
                            if deletingClientId == orphan.clientId {
                                ProgressView()
                                    .padding(.trailing, DesignConstants.Spacing.step2x)
                                Text("Deleting…")
                            } else {
                                Image(systemName: "trash")
                                Text("Hold to delete")
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(deletingClientId != nil)
                    .buttonStyle(HoldToConfirmPrimitiveStyle(config: {
                        var config = HoldToConfirmStyleConfig.default
                        config.duration = 2.0
                        config.backgroundColor = .colorCaution
                        return config
                    }()))
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("Orphaned Inboxes")
        .toolbarTitleDisplayMode(.inline)
        .task {
            loadOrphans()
        }
        .refreshable {
            loadOrphans()
        }
    }

    private func orphanRow(orphan: OrphanedInboxDetail) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            HStack {
                Text("Orphaned Inbox")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
            }

            labeledValue("Age", waitingDuration(since: orphan.createdAt))
            labeledValue("Created", orphan.createdAt.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            labeledValue("Client ID", orphan.clientId, monospaced: true)
            labeledValue("Inbox ID", orphan.inboxId, monospaced: true)
            labeledValue("Drafts", "\(orphan.draftConversationIds.count)")
        }
        .padding(.vertical, DesignConstants.Spacing.stepHalf)
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

    private func deleteOrphan(_ orphan: OrphanedInboxDetail) {
        guard deletingClientId == nil else { return }
        deletingClientId = orphan.clientId
        Task {
            do {
                try await session.deleteOrphanedInbox(clientId: orphan.clientId, inboxId: orphan.inboxId)
            } catch {
                Log.error("Failed to delete orphaned inbox \(orphan.clientId): \(error)")
            }
            loadOrphans()
            deletingClientId = nil
        }
    }

    private func loadOrphans() {
        do {
            orphans = try session.orphanedInboxDetails()
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
        OrphanedInboxDebugView(session: MockInboxesService())
    }
}
