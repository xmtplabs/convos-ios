import ConvosCore
import CoreHaptics
import SwiftUI

struct ExplodeConvoSheet: View {
    var isScheduled: Bool = false
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
    @State private var highlightedMenuIndex: Int?
    @State private var explosionTrigger: Int = 0

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

    @ViewBuilder
    private var cardContent: some View {
        if isScheduled {
            scheduledCardContent
        } else {
            scheduleCardContent
        }
    }

    private var scheduledCardContent: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Text("The fuse is lit")
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)

                    Text("It can't be changed or cancelled.")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.bottom, DesignConstants.Spacing.step2x)

                holdToExplodeButton
            }
            .padding(DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step3x)
            .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.mediumLargest))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignConstants.CornerRadius.mediumLargest))
        }
    }

    private var scheduleCardContent: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Text("Start an unstoppable countdown")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .padding(.horizontal, DesignConstants.Spacing.step3x)

                    scheduleMenuContent
                }

                holdToExplodeButton
            }
            .padding(DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step3x)
            .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.mediumLargest))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignConstants.CornerRadius.mediumLargest))
        }
    }

    private var scheduleMenuItems: [(label: String, showsChevron: Bool)] {
        var items: [(label: String, showsChevron: Bool)] = [
            ("60 seconds", false),
            ("1 hour", false),
            ("24 hours", false),
        ]
        if sundayAtMidnight != nil {
            items.append(("Sunday at midnight", false))
        }
        items.append(("Choose date and time", true))
        return items
    }

    private var scheduleMenuContent: some View {
        let items = scheduleMenuItems
        let rowHeight: CGFloat = DesignConstants.Spacing.step11x
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.label)
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    if item.showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                    }
                }
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .frame(height: rowHeight)
            }
        }
        .background(alignment: .topLeading) {
            if highlightedMenuIndex != nil {
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: rowHeight)
                    .frame(maxWidth: .infinity)
                    .offset(y: CGFloat(highlightedMenuIndex ?? 0) * rowHeight)
                    .transition(.opacity.animation(.easeOut(duration: 0.08)))
            }
        }
        .animation(.smooth(duration: 0.15), value: highlightedMenuIndex)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: highlightedMenuIndex) { _, newValue in
            newValue != nil
        }
        .coordinateSpace(name: "scheduleMenu")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("scheduleMenu"))
                .onChanged { value in
                    let index = Int(value.location.y / rowHeight)
                    let newIndex = (index >= 0 && index < items.count) ? index : nil
                    if newIndex != highlightedMenuIndex {
                        highlightedMenuIndex = newIndex
                    }
                }
                .onEnded { _ in
                    if let index = highlightedMenuIndex {
                        performScheduleMenuAction(at: index)
                    }
                    highlightedMenuIndex = nil
                }
        )
    }

    private func performScheduleMenuAction(at index: Int) {
        let hasSunday = sundayAtMidnight != nil
        switch index {
        case 0:
            pendingSchedule = .init(label: "60 seconds", date: Date().addingTimeInterval(60))
            showingConfirmation = true
        case 1:
            pendingSchedule = .init(label: "1 hour", date: Date().addingTimeInterval(3600))
            showingConfirmation = true
        case 2:
            pendingSchedule = .init(label: "24 hours", date: Date().addingTimeInterval(86400))
            showingConfirmation = true
        case 3 where hasSunday:
            if let sunday = sundayAtMidnight {
                pendingSchedule = .init(label: "Sunday at midnight", date: sunday, preposition: "on")
                showingConfirmation = true
            }
        default:
            customDate = Date().addingTimeInterval(3600)
            showingCustomDatePicker = true
        }
    }

    private var holdToExplodeButton: some View {
        let explodeAction = {
            explodeState = .exploding
            explodeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.15))
                guard !Task.isCancelled else { return }
                explodeState = .exploded
                playExplosionRipple()
                explosionTrigger += 1
                try? await Task.sleep(for: .seconds(0.7))
                guard !Task.isCancelled else { return }
                onExplodeNow()
            }
        }
        var config: HoldToConfirmStyleConfig = .default
        config.backgroundColor = .colorCaution
        config.verticalPadding = DesignConstants.Spacing.step3x
        config.cornerRadius = DesignConstants.CornerRadius.mediumLarger
        config.duration = 1.5
        return Button(action: explodeAction) {
            VStack(spacing: DesignConstants.Spacing.stepHalf) {
                ShatteringText(
                    text: "Explode Now",
                    isExploded: explodeState.isExploded,
                    config: Constant.shatterConfig
                )
                .font(.body)
                ShatteringText(
                    text: "Tap and hold",
                    isExploded: explodeState.isExploded,
                    config: Constant.shatterConfig
                )
                .font(.caption)
                .opacity(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: config))
        .keyframeAnimator(
            initialValue: ExplosionKeyframes(),
            trigger: explosionTrigger
        ) { content, value in
            content
                .scaleEffect(value.scale)
                .offset(x: value.xOffset)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.1, duration: 0.1, spring: .bouncy(duration: 0.1))
                SpringKeyframe(0.96, duration: 0.08)
                SpringKeyframe(1.04, duration: 0.08)
                SpringKeyframe(0.98, duration: 0.06)
                SpringKeyframe(1.0, duration: 0.12)
            }
            KeyframeTrack(\.xOffset) {
                LinearKeyframe(0, duration: 0.06)
                LinearKeyframe(6, duration: 0.035)
                LinearKeyframe(-6, duration: 0.035)
                LinearKeyframe(4, duration: 0.035)
                LinearKeyframe(-4, duration: 0.035)
                LinearKeyframe(3, duration: 0.035)
                LinearKeyframe(-3, duration: 0.035)
                LinearKeyframe(1, duration: 0.025)
                LinearKeyframe(-1, duration: 0.025)
                LinearKeyframe(0, duration: 0.02)
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

    private func playExplosionRipple() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            try engine.start()

            let events: [CHHapticEvent] = [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                    ],
                    relativeTime: 0.05,
                    duration: 1.0
                ),
            ]

            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
            engine.notifyWhenPlayersFinished { _ in .stopEngine }
        } catch {}
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

    private struct ExplosionKeyframes {
        var scale: CGFloat = 1.0
        var xOffset: CGFloat = 0
    }

    private enum Constant {
        static let shatterConfig: ShatteringTextAnimationConfig = .init(
            letterHorizontalRange: 30...60,
            letterVerticalRange: 20...45,
            letterRotationRange: 25...70,
            letterScaleRange: 1.2...2.5,
            letterBlurRadius: 1.5,
            letterAnimationResponse: 0.45,
            letterAnimationDamping: 0.5,
            letterStaggerDelay: 0.015
        )
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
