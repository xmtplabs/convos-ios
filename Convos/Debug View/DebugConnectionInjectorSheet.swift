import ConvosConnections
import ConvosCore
import SwiftUI

extension View {
    /// Presents the debug connection injector sheet when `isPresented` is true. In Release
    /// builds the sheet body is empty so the production binary doesn't carry any of this UI.
    func debugConnectionInjectorSheet(
        isPresented: Binding<Bool>,
        conversationId: String,
        messagingService: any MessagingServiceProtocol
    ) -> some View {
        sheet(isPresented: isPresented) {
            #if DEBUG
            DebugConnectionInjectorSheet(
                conversationId: conversationId,
                messagingService: messagingService,
                onDismiss: { isPresented.wrappedValue = false }
            )
            #else
            EmptyView()
            #endif
        }
    }
}

#if DEBUG

/// Debug-only sheet for injecting fake `ConnectionPayload`s into the active conversation
/// to exercise agent code paths that we cannot trigger manually — for example, a HealthKit
/// background-delivery wakeup. Bound to the testtube button in `MessagesMediaButtonsView`.
///
/// Compiles only in DEBUG builds; the entire view + presenter chain disappears in Release.
struct DebugConnectionInjectorSheet: View {
    let conversationId: String
    let messagingService: any MessagingServiceProtocol
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Connections") {
                    NavigationLink {
                        DebugHealthBackgroundUpdateView(
                            conversationId: conversationId,
                            messagingService: messagingService,
                            onSent: onDismiss
                        )
                    } label: {
                        DebugRow(
                            iconSystemName: "heart.text.square.fill",
                            iconColor: .pink,
                            title: "Health background update",
                            subtitle: "Send a fake HealthKit observer fire to this conversation."
                        )
                    }
                }
            }
            .navigationTitle("Test attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}

private struct DebugRow: View {
    let iconSystemName: String
    let iconColor: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconSystemName)
                .font(.system(size: 22))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DebugHealthBackgroundUpdateView: View {
    let conversationId: String
    let messagingService: any MessagingServiceProtocol
    let onSent: () -> Void

    @State private var typeIdentifier: HealthSampleType = .stepCount
    @State private var sampleValueText: String = "1500"
    @State private var unitText: String = "count"
    @State private var minutesAgoText: String = "10"
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var sampleValue: Double? {
        Double(sampleValueText.trimmingCharacters(in: .whitespaces))
    }

    private var minutesAgo: Int {
        Int(minutesAgoText) ?? 10
    }

    private var canSend: Bool {
        !isSending && sampleValue != nil
    }

    var body: some View {
        Form {
            Section("Type") {
                Picker("Sample type", selection: $typeIdentifier) {
                    ForEach(HealthSampleType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Sample") {
                TextField("Value", text: $sampleValueText)
                    .keyboardType(.decimalPad)
                TextField("Unit (e.g. count, m, kcal)", text: $unitText)
                TextField("Minutes ago", text: $minutesAgoText)
                    .keyboardType(.numberPad)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if isSending { ProgressView() }
                        Text(isSending ? "Sending..." : "Send to conversation")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!canSend)
            }
        }
        .navigationTitle("Health update")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func send() async {
        guard let sampleValue else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let now = Date()
        let sampleDate = now.addingTimeInterval(TimeInterval(-minutesAgo * 60))
        let sample = HealthSample(
            type: typeIdentifier,
            startDate: sampleDate,
            endDate: sampleDate,
            value: sampleValue,
            unit: unitText.isEmpty ? "count" : unitText
        )
        let payload = ConnectionPayload(
            source: .health,
            capturedAt: now,
            body: .health(HealthPayload(
                summary: "DEBUG: 1 fake \(typeIdentifier.displayName.lowercased()) sample.",
                samples: [sample],
                rangeStart: sampleDate,
                rangeEnd: now
            ))
        )

        do {
            try await messagingService.sendDebugConnectionPayload(payload, to: conversationId)
            onSent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#endif
