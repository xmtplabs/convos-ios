import ConvosCore
import SwiftUI

struct ExplodeConvoSheet: View {
    let onSchedule: (Date) -> Void
    let onExplodeNow: () -> Void
    let onDismiss: () -> Void

    @State private var showingConfirmation: Bool = false
    @State private var pendingSchedule: ScheduleOption?
    @State private var showingCustomDatePicker: Bool = false
    @State private var customDate: Date = Date().addingTimeInterval(3600)
    @State private var explodeState: ExplodeState = .ready
    @State private var explodeTask: Task<Void, Never>?
    @State private var appeared: Bool = false

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

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.4 : 0.0)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            cardContent
                .padding(.horizontal, DesignConstants.Spacing.step10x)
                .scaleEffect(appeared ? 1.0 : 0.85)
                .opacity(appeared ? 1.0 : 0.0)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: appeared)
        .onAppear { appeared = true }
        .alert(
            "Light the fuse?",
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
            Text("The countdown can't be changed or cancelled once it starts")
        }
        .sheet(isPresented: $showingCustomDatePicker) {
            customDatePickerSheet
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Start an unstoppable countdown")
                .font(.subheadline)
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
                        pendingSchedule = .init(label: "Sunday at midnight", date: sunday, preposition: "on")
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

            holdToExplodeButton
                .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding(DesignConstants.Spacing.step6x)
        .background(.colorBackgroundRaised)
        .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        .shadow(color: .black.opacity(0.15), radius: 24, x: 0, y: 12)
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
            readyText: "Explode Now",
            explodingText: "Exploding..."
        ) {
            explodeState = .exploding
            onExplodeNow()
            explodeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                explodeState = .exploded
                try? await Task.sleep(for: .seconds(ExplodeState.explodedAnimationDelay))
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        }
        .onDisappear { explodeTask?.cancel() }
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
            .navigationTitle("Explode")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        showingCustomDatePicker = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    let confirmAction = {
                        showingCustomDatePicker = false
                        let date = max(customDate, Date().addingTimeInterval(60))
                        pendingSchedule = .init(label: date.formatted(date: .abbreviated, time: .shortened), date: date, preposition: "on")
                        showingConfirmation = true
                    }
                    Button(action: confirmAction) {
                        Label("Done", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .tint(.colorBackgroundInverted)
                }
            }
        }
        .presentationDetents([.height(340)])
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onDismiss()
        }
    }

    private struct ScheduleOption {
        let label: String
        let date: Date
        var preposition: String = "in"
    }
}

#Preview("Explode Dialog") {
    @Previewable @State var presenting: Bool = true
    ZStack {
        VStack {
            let toggleAction = { presenting.toggle() }
            Button(action: toggleAction) {
                Text("Toggle Explode Dialog")
            }
        }
        if presenting {
            ExplodeConvoSheet(
                onSchedule: { _ in presenting = false },
                onExplodeNow: {},
                onDismiss: { presenting = false }
            )
        }
    }
}

#Preview("Date Picker") {
    @Previewable @State var customDate: Date = Date().addingTimeInterval(3600)
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
        .navigationTitle("Explode")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .cancel) {}
            }
            ToolbarItem(placement: .confirmationAction) {
                let doneAction = {}
                Button(action: doneAction) {
                    Label("Done", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
    .presentationDetents([.height(340)])
}
