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
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var fixture: HealthDebugFixture {
        HealthDebugFixture.fixture(for: typeIdentifier, now: Date())
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

            Section("Preview") {
                LabeledContent("Summary") {
                    Text(fixture.payload.summary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Samples", value: "\(fixture.payload.samples.count)")
                LabeledContent("Range") {
                    Text(rangeDescription(fixture.payload))
                        .multilineTextAlignment(.trailing)
                }
                ForEach(Array(fixture.payload.samples.enumerated()), id: \.offset) { _, sample in
                    LabeledContent(sample.type.displayName) {
                        Text("\(formatted(sample.value)) \(sample.unit)")
                            .multilineTextAlignment(.trailing)
                    }
                }
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
                .disabled(isSending)
            }
        }
        .navigationTitle("Health update")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rangeDescription(_ payload: HealthPayload) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(formatter.string(from: payload.rangeStart)) – \(formatter.string(from: payload.rangeEnd))"
    }

    private func formatted(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    @MainActor
    private func send() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let payload = ConnectionPayload(
            source: .health,
            capturedAt: Date(),
            body: .health(fixture.payload)
        )

        do {
            try await messagingService.sendDebugConnectionPayload(payload, to: conversationId)
            onSent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HealthDebugFixture {
    let payload: HealthPayload

    static func fixture(for type: HealthSampleType, now: Date) -> HealthDebugFixture {
        switch type {
        case .stepCount:
            return makeFixture(
                type: type,
                summary: "4,287 steps in the last hour.",
                rangeMinutes: 60,
                samples: [
                    Sample(value: 1_540, unit: "count", offsetMinutes: -45),
                    Sample(value: 2_120, unit: "count", offsetMinutes: -25),
                    Sample(value: 627, unit: "count", offsetMinutes: -5),
                ],
                now: now
            )
        case .distanceWalkingRunning:
            return makeFixture(
                type: type,
                summary: "1.20 km walked in the last 30 minutes.",
                rangeMinutes: 30,
                samples: [
                    Sample(value: 1_200, unit: "m", offsetMinutes: -10),
                ],
                now: now
            )
        case .activeEnergyBurned:
            return makeFixture(
                type: type,
                summary: "285 active kcal burned in the last hour.",
                rangeMinutes: 60,
                samples: [
                    Sample(value: 110, unit: "kcal", offsetMinutes: -45),
                    Sample(value: 175, unit: "kcal", offsetMinutes: -15),
                ],
                now: now
            )
        case .heartRateVariabilitySDNN:
            return makeFixture(
                type: type,
                summary: "HRV: 42ms (last reading 5 minutes ago).",
                rangeMinutes: 60,
                samples: [
                    Sample(value: 42, unit: "ms", offsetMinutes: -5),
                ],
                now: now
            )
        case .sleepAnalysis:
            return makeFixture(
                type: type,
                summary: "Slept 7h 32m last night (in bed 11:14 PM – 7:08 AM).",
                rangeMinutes: 8 * 60,
                samples: [
                    Sample(value: 1, unit: "stage", offsetMinutes: -8 * 60),
                    Sample(value: 2, unit: "stage", offsetMinutes: -7 * 60),
                    Sample(value: 3, unit: "stage", offsetMinutes: -5 * 60),
                ],
                now: now
            )
        case .mindfulSession:
            return makeFixture(
                type: type,
                summary: "10-minute mindful session 30 minutes ago.",
                rangeMinutes: 60,
                samples: [
                    Sample(value: 600, unit: "s", offsetMinutes: -40),
                ],
                now: now
            )
        case .workout:
            return makeFixture(
                type: type,
                summary: "30-minute outdoor run, 5.0 km, 350 kcal.",
                rangeMinutes: 35,
                samples: [
                    Sample(value: 1_800, unit: "s", offsetMinutes: -35),
                    Sample(value: 5_000, unit: "m", offsetMinutes: -35),
                    Sample(value: 350, unit: "kcal", offsetMinutes: -35),
                ],
                now: now
            )
        }
    }

    private struct Sample {
        let value: Double
        let unit: String
        let offsetMinutes: Int
    }

    private static func makeFixture(
        type: HealthSampleType,
        summary: String,
        rangeMinutes: Int,
        samples: [Sample],
        now: Date
    ) -> HealthDebugFixture {
        let rangeStart = now.addingTimeInterval(TimeInterval(-rangeMinutes * 60))
        let mappedSamples = samples.map { sample -> HealthSample in
            let date = now.addingTimeInterval(TimeInterval(sample.offsetMinutes * 60))
            return HealthSample(
                type: type,
                startDate: date,
                endDate: date,
                value: sample.value,
                unit: sample.unit
            )
        }
        return HealthDebugFixture(
            payload: HealthPayload(
                summary: "DEBUG: \(summary)",
                samples: mappedSamples,
                rangeStart: rangeStart,
                rangeEnd: now
            )
        )
    }
}

#endif
