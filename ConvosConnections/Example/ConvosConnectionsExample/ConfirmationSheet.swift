import ConvosConnections
import SwiftUI

/// Presented whenever the manager's always-confirm gate asks the host to approve a write.
///
/// Shows the pre-computed human summary, the connection kind, the capability, and the full
/// argument dictionary. Approve resumes with `.approved`; Deny and swipe-to-dismiss both
/// resume with `.denied`.
struct ConfirmationSheet: View {
    let request: ConfirmationRequest
    let handler: ExampleConfirmationHandler

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: request.kind.systemImageName)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agent wants to \(request.actionName)")
                                .font(.headline)
                            Text("\(request.kind.displayName) · \(request.capability.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(request.humanSummary)
                        .font(.callout)
                }

                Section("Arguments") {
                    ForEach(Array(request.arguments.keys).sorted(), id: \.self) { key in
                        HStack(alignment: .top) {
                            Text(key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.render(request.arguments[key] ?? .null))
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Context") {
                    LabeledContent("Invocation ID", value: request.invocationId)
                        .font(.caption.monospaced())
                    LabeledContent("Conversation ID", value: request.conversationId)
                        .font(.caption.monospaced())
                    LabeledContent("Requested", value: request.requestedAt.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                }
            }
            .navigationTitle("Confirm write")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Deny", role: .destructive) {
                        handler.resolve(.denied)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") {
                        handler.resolve(.approved)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static func render(_ value: ArgumentValue) -> String {
        switch value {
        case .string(let v): return "\"\(v)\""
        case .bool(let v): return String(v)
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .date(let v): return v.formatted()
        case .iso8601DateTime(let v): return v
        case .enumValue(let v): return ".\(v)"
        case .array(let values):
            let inner = values.map { render($0) }.joined(separator: ", ")
            return "[\(inner)]"
        case .null: return "null"
        }
    }
}

private extension ConnectionCapability {
    var displayName: String {
        switch self {
        case .read: return "read"
        case .writeCreate: return "write (create)"
        case .writeUpdate: return "write (update)"
        case .writeDelete: return "write (delete)"
        }
    }
}
