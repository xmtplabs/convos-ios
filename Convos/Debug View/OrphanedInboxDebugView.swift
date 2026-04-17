import ConvosCore
import SwiftUI

struct OrphanedInboxDebugView: View {
    let session: any SessionManagerProtocol
    @State private var isOrphaned: Bool = false
    @State private var loadError: String?
    @State private var isDeleting: Bool = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(isOrphaned ? "Orphaned" : "OK")
                        .foregroundStyle(isOrphaned ? .red : .colorTextSecondary)
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Account")
            }

            if let loadError {
                Section {
                    Text(loadError)
                        .foregroundStyle(.red)
                }
            }

            if isOrphaned {
                Section {
                    Text("The authorized inbox has no joined conversations and no tagged drafts. Reset the account to start clean.")
                        .foregroundStyle(.colorTextSecondary)
                    Button {
                        resetAccount()
                    } label: {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .padding(.trailing, DesignConstants.Spacing.step2x)
                                Text("Resetting…")
                            } else {
                                Image(systemName: "trash")
                                Text("Hold to reset account")
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isDeleting)
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
        .navigationTitle("Orphaned Inbox")
        .toolbarTitleDisplayMode(.inline)
        .task {
            refresh()
        }
        .refreshable {
            refresh()
        }
    }

    private func resetAccount() {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            do {
                try await session.deleteAllInboxes()
            } catch {
                Log.error("Failed to reset account: \(error)")
            }
            refresh()
            isDeleting = false
        }
    }

    private func refresh() {
        do {
            isOrphaned = try session.isAccountOrphaned()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        OrphanedInboxDebugView(session: MockInboxesService())
    }
}
