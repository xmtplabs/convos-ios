import ConvosCore
import SwiftUI

struct HiddenMessagesView: View {
    private let load: () async throws -> [HiddenMessageDebugEntry]

    @State private var entries: [HiddenMessageDebugEntry] = []
    @State private var isLoading: Bool = true
    @State private var errorText: String?

    init(load: @escaping () async throws -> [HiddenMessageDebugEntry]) {
        self.load = load
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12.0) {
                    ProgressView()
                    Text("Loading hidden messages…")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                ScrollView {
                    Text(errorText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.colorTextSecondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if entries.isEmpty {
                VStack(spacing: 8.0) {
                    Text("No hidden messages")
                        .font(.body)
                    Text("XMTP returned no messages with hidden content types for this conversation.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(entries) { entry in
                            HiddenMessageRow(entry: entry)
                        }
                    } header: {
                        Text("\(entries.count) hidden \(entries.count == 1 ? "message" : "messages")")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Hidden messages")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        errorText = nil
        do {
            let fetched = try await load()
            entries = fetched.sorted { $0.date > $1.date }
        } catch {
            errorText = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct HiddenMessageRow: View {
    let entry: HiddenMessageDebugEntry

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4.0) {
            HStack {
                Text(entry.reason.rawValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            Text(entry.contentTypeDescription)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.colorTextSecondary)
            Text(entry.summary)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.colorTextPrimary)
            Text("from \(entry.senderInboxId)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4.0)
    }
}

#Preview {
    NavigationStack {
        HiddenMessagesView(load: {
            [
                HiddenMessageDebugEntry(
                    id: "1",
                    date: Date(),
                    senderInboxId: "0xabc123def456789abc123def456789abc123def4",
                    contentTypeDescription: "convos.org/profile_update:1.0",
                    summary: "name=\"Alice\", avatar, kind=agent",
                    reason: .profileUpdate
                ),
                HiddenMessageDebugEntry(
                    id: "2",
                    date: Date().addingTimeInterval(-3600),
                    senderInboxId: "0xdef456789abc123def456789abc123def456789a",
                    contentTypeDescription: "convos.org/typing_indicator:1.0",
                    summary: "isTyping=true",
                    reason: .typingIndicator
                ),
            ]
        })
    }
}
