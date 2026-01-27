import SwiftUI

struct ScheduleExplosionView: View {
    let onSchedule: (Date) -> Void
    let onExplodeNow: () -> Void
    let onCancel: () -> Void

    @State private var showingCustomPicker: Bool = false
    @State private var customDate: Date = Date().addingTimeInterval(3600)

    private var sundayAtMidnight: Date {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilSunday = (8 - weekday) % 7
        let adjustedDays = daysUntilSunday == 0 ? 7 : daysUntilSunday
        guard let nextSunday = calendar.date(byAdding: .day, value: adjustedDays, to: today) else {
            return today
        }
        return calendar.startOfDay(for: nextSunday)
    }

    private var minimumCustomDate: Date {
        Date().addingTimeInterval(60)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.bottom, DesignConstants.Spacing.step6x)

            VStack(spacing: DesignConstants.Spacing.stepX) {
                scheduleOptionRow(
                    title: "1 minute",
                    duration: 60
                )
                scheduleOptionRow(
                    title: "1 hour",
                    duration: 3600
                )
                scheduleOptionRow(
                    title: "24 hours",
                    duration: 86400
                )
                scheduleOptionRow(
                    icon: "calendar",
                    title: sundayOptionTitle,
                    date: sundayAtMidnight
                )
                customOptionRow
            }

            Spacer()
                .frame(height: DesignConstants.Spacing.step6x)

            explodeNowButton
                .padding(.bottom, DesignConstants.Spacing.step3x)

            cancelButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, DesignConstants.Spacing.step4x)
        .sheet(isPresented: $showingCustomPicker) {
            customDatePickerSheet
        }
    }

    private var headerView: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Image("explodeIcon")
                .font(.system(size: 32))
                .foregroundStyle(.colorOrange)
                .frame(width: 64, height: 64)
                .background(
                    Circle()
                        .fill(.colorOrange.opacity(0.15))
                )

            Text("Explode")
                .font(.title.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("Once scheduled, it cannot be cancelled")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var sundayOptionTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE 'at' h:mm a"
        return formatter.string(from: sundayAtMidnight)
    }

    private func scheduleOptionRow(title: String, duration: TimeInterval) -> some View {
        let action = {
            let expiresAt = Date().addingTimeInterval(duration)
            onSchedule(expiresAt)
        }
        return Button(action: action) {
            scheduleRowContent(title: title)
        }
        .buttonStyle(ScheduleOptionButtonStyle())
    }

    private func scheduleOptionRow(icon: String, title: String, date: Date) -> some View {
        let action = {
            onSchedule(date)
        }
        return Button(action: action) {
            scheduleRowContent(icon: icon, title: title)
        }
        .buttonStyle(ScheduleOptionButtonStyle())
    }

    private func scheduleRowContent(title: String) -> some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Text(title)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.colorTextTertiary)
        }
    }

    private func scheduleRowContent(icon: String, title: String) -> some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.colorOrange)
                .frame(width: 24)

            Text(title)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.colorTextTertiary)
        }
    }

    private var customOptionRow: some View {
        let action = {
            showingCustomPicker = true
        }
        return Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: "calendar.badge.clock")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.colorOrange)
                    .frame(width: 24)

                Text("Custom")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextTertiary)
            }
        }
        .buttonStyle(ScheduleOptionButtonStyle())
    }

    private var explodeNowButton: some View {
        let action = {
            onExplodeNow()
        }
        return Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "bolt.fill")
                Text("Explode now")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(.colorCaution)
            )
        }
        .buttonStyle(.plain)
    }

    private var cancelButton: some View {
        let action = {
            onCancel()
        }
        return Button(action: action) {
            Text("Cancel")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step2x)
    }

    private var customDatePickerSheet: some View {
        VStack(spacing: 0) {
            DatePicker(
                "Explode at",
                selection: $customDate,
                in: minimumCustomDate...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(.horizontal, DesignConstants.Spacing.step4x)

            Spacer()
                .frame(height: DesignConstants.Spacing.step4x)

            VStack(spacing: DesignConstants.Spacing.step3x) {
                let confirmAction = {
                    showingCustomPicker = false
                    onSchedule(customDate)
                }
                Button(action: confirmAction) {
                    Text("Schedule")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignConstants.Spacing.step3x)
                        .background(
                            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                                .fill(.colorOrange)
                        )
                }
                .buttonStyle(.plain)

                let cancelAction = {
                    showingCustomPicker = false
                }
                Button(action: cancelAction) {
                    Text("Cancel")
                        .font(.body)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.bottom, DesignConstants.Spacing.step4x)
        }
        .padding(.top, DesignConstants.Spacing.step4x)
        .presentationDetents([.large])
    }
}

private struct ScheduleOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(Color.colorFillMinimal)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    @Previewable @State var presenting: Bool = true
    VStack {
        let action = {
            presenting.toggle()
        }
        Button(action: action) {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        ScheduleExplosionView(
            onSchedule: { date in
                print("Scheduled for: \(date)")
            },
            onExplodeNow: {
                print("Explode now!")
            },
            onCancel: {
                presenting = false
            }
        )
        .background(.colorBackgroundRaised)
    }
}
