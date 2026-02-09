import ConvosCore
import SwiftUI

struct ExplodeConvoSheet: View {
    let onSchedule: (Date) -> Void
    let onExplodeNow: () -> Void
    let onCancel: () -> Void

    @State private var showingConfirmation: Bool = false
    @State private var pendingSchedule: ScheduleOption?
    @State private var showingCustomDatePicker: Bool = false
    @State private var customDate: Date = Date().addingTimeInterval(3600)
    @State private var explodeState: ExplodeState = .ready

    private var sundayAtMidnight: Date? {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilSunday = (8 - weekday) % 7
        let adjustedDays = daysUntilSunday == 0 ? 7 : daysUntilSunday
        guard let nextSunday = calendar.date(byAdding: .day, value: adjustedDays, to: today) else {
            return nil
        }
        return calendar.startOfDay(for: nextSunday)
    }

    private var confirmationTitle: String {
        guard let pending = pendingSchedule else {
            return "Explode convo?"
        }
        return "Explode convo in \(pending.label)?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Explode")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("Start an unstoppable countdown to destroy all messages and members")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(alignment: .leading, spacing: 0) {
                scheduleRow(label: "60 seconds") {
                    pendingSchedule = .init(label: "60 seconds", date: Date().addingTimeInterval(60))
                    showingConfirmation = true
                }

                scheduleRow(label: "1 hour") {
                    pendingSchedule = .init(label: "1 hour", date: Date().addingTimeInterval(3600))
                    showingConfirmation = true
                }

                scheduleRow(label: "24 hours") {
                    pendingSchedule = .init(label: "24 hours", date: Date().addingTimeInterval(86400))
                    showingConfirmation = true
                }

                if let sunday = sundayAtMidnight {
                    scheduleRow(label: "Sunday at midnight") {
                        pendingSchedule = .init(label: "Sunday at midnight", date: sunday)
                        showingConfirmation = true
                    }
                }

                let chooseDateAction = {
                    customDate = Date().addingTimeInterval(3600)
                    showingCustomDatePicker = true
                }
                Button(action: chooseDateAction) {
                    HStack {
                        Text("Choose date and time")
                            .foregroundStyle(.colorTextPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                    }
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: DesignConstants.Spacing.step2x) {
                holdToExplodeButton

                let cancelAction = { onCancel() }
                Button(action: cancelAction) {
                    Text("Cancel")
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .alert(
            confirmationTitle,
            isPresented: $showingConfirmation
        ) {
            let cancelAction = { pendingSchedule = nil }
            Button("Cancel", role: .cancel, action: cancelAction)

            let confirmAction = {
                guard let pending = pendingSchedule else { return }
                onSchedule(pending.date)
                pendingSchedule = nil
            }
            Button("Start", role: .destructive, action: confirmAction)
        } message: {
            Text("The timer cannot be changed or cancelled once it starts.")
        }
        .sheet(isPresented: $showingCustomDatePicker) {
            customDatePickerSheet
        }
    }

    @ViewBuilder
    private func scheduleRow(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
        }
        .buttonStyle(.plain)
    }

    private var holdToExplodeButton: some View {
        ExplodeButton(
            state: explodeState,
            readyText: "Hold to Explode Now",
            explodingText: "Exploding..."
        ) {
            explodeState = .exploding
            onExplodeNow()
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                explodeState = .exploded
                try? await Task.sleep(for: .seconds(ExplodeState.explodedAnimationDelay))
                onCancel()
            }
        }
    }

    @ViewBuilder
    private var customDatePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "Explode at",
                selection: $customDate,
                in: Date().addingTimeInterval(60)...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        showingCustomDatePicker = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Confirm", role: .destructive) {
                        showingCustomDatePicker = false
                        onSchedule(customDate)
                    }
                    .tint(.colorBackgroundInverted)
                }
            }
            .navigationTitle("Explode")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(340)])
    }

    private struct ScheduleOption {
        let label: String
        let date: Date
    }
}

#Preview {
    @Previewable @State var presenting: Bool = true
    VStack {
        let toggleAction = { presenting.toggle() }
        Button(action: toggleAction) {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        ExplodeConvoSheet(
            onSchedule: { _ in },
            onExplodeNow: {},
            onCancel: {}
        )
        .background(.colorBackgroundRaised)
    }
}
