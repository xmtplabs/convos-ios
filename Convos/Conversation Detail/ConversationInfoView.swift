import ConvosCore
import SwiftUI

struct FeatureRowItem<AccessoryView: View>: View {
    let imageName: String?
    let symbolName: String
    let title: String
    let subtitle: String?
    var iconBackgroundColor: Color = .colorOrange
    var iconForegroundColor: Color = .white
    @ViewBuilder let accessoryView: () -> AccessoryView

    var image: Image {
        if let imageName {
            Image(imageName)
        } else {
            Image(systemName: symbolName)
        }
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Group {
                image
                    .font(.headline)
                    .padding(.horizontal, DesignConstants.Spacing.step2x)
                    .padding(.vertical, 10.0)
                    .foregroundStyle(iconForegroundColor)
            }
            .frame(width: 40.0, height: 40.0)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(iconBackgroundColor)
                    .aspectRatio(1.0, contentMode: .fit)
            )

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            accessoryView()
        }
    }
}

#Preview {
    FeatureRowItem(imageName: nil, symbolName: "eyeglasses", title: "Peek-a-boo", subtitle: "Blur when people peek") {
        SoonLabel()
    }
    .padding(DesignConstants.Spacing.step4x)
}

struct ConversationInfoView: View {
    @Bindable var viewModel: ConversationViewModel
    let focusCoordinator: FocusCoordinator

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var showingExplodeConfirmation: Bool = false
    @State private var pendingExplosionDate: Date?
    @State private var pendingExplosionLabel: String?
    @State private var showingCustomDatePicker: Bool = false
    @State private var customDate: Date = Date().addingTimeInterval(3600)
    @State private var presentingEditView: Bool = false
    @State private var showingLockConfirmation: Bool = false
    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var exportedLogsURL: URL?

    private let maxMembersToShow: Int = 6
    private var displayedMembers: [ConversationMember] {
        let sortedMembers = viewModel.conversation.members.sortedByRole()
        return Array(sortedMembers.prefix(maxMembersToShow))
    }
    private var showViewAllMembers: Bool {
        viewModel.conversation.members.count > maxMembersToShow
    }

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

    private func formatExplosionDuration(for date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 {
            return "now"
        } else if interval < 120 {
            return "1 minute"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minutes"
        } else if interval < 7200 {
            return "1 hour"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hours"
        } else {
            let days = Int(interval / 86400)
            return days == 1 ? "1 day" : "\(days) days"
        }
    }

    private var explosionAlertTitle: String {
        guard let label = pendingExplosionLabel else {
            return "Explode convo?"
        }
        if label == "now" {
            return "Explode convo now?"
        }
        if label.contains("Sunday") || label.contains("midnight") {
            return "Explode convo on \(label)?"
        }
        return "Explode convo in \(label)?"
    }

    @ViewBuilder
    private var convoCodeRow: some View {
        let isUnavailable = viewModel.isLocked || viewModel.isFull
        let subtitle = if isUnavailable {
            "None"
        } else {
            "\(ConfigManager.shared.currentEnvironment.relyingPartyIdentifier)/\(viewModel.invite.urlSlug)"
        }

        if !isUnavailable, let inviteURL = viewModel.invite.inviteURL {
            // Entire row is ShareLink when available
            ShareLink(item: inviteURL) {
                convoCodeRowContent(subtitle: subtitle, showShareIcon: true)
            }
            .buttonStyle(.plain)
        } else {
            // Row with tap gesture for "full" alert
            convoCodeRowContent(subtitle: subtitle, showShareIcon: false)
                .contentShape(Rectangle())
                .onTapGesture {
                    if viewModel.isFull {
                        showingFullInfo = true
                    }
                }
                .opacity(viewModel.isLocked ? 0.5 : 1.0)
        }
    }

    @ViewBuilder
    private func convoCodeRowContent(subtitle: String, showShareIcon: Bool) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Group {
                Image(systemName: "qrcode")
                    .font(.headline)
                    .padding(.horizontal, DesignConstants.Spacing.step2x)
                    .padding(.vertical, 10.0)
                    .foregroundStyle(viewModel.isFull ? .colorTextSecondary : .colorTextPrimary)
            }
            .frame(width: 40.0, height: 40.0)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(Color.colorFillMinimal)
                    .aspectRatio(1.0, contentMode: .fit)
            )

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text("Convo code")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if showShareIcon {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }

    @ViewBuilder
    private func explosionCountdownRow(expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Group {
                    Image("explodeIcon")
                        .font(.headline)
                        .padding(.horizontal, DesignConstants.Spacing.step2x)
                        .padding(.vertical, 10.0)
                        .foregroundStyle(.white)
                }
                .frame(width: 40.0, height: 40.0)
                .background(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                        .fill(Color.colorOrange)
                        .aspectRatio(1.0, contentMode: .fit)
                )

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text("Explodes in")
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Text(formatExplosionCountdown(expiresAt, from: context.date))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.colorOrange)
                }

                Spacer()
            }
        }
    }

    private func formatExplosionCountdown(_ date: Date, from now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "00:00:00" }

        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)d \(remainingHours)h"
        } else {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
    }

    @ViewBuilder
    private var lockRow: some View {
        FeatureRowItem(
            imageName: nil,
            symbolName: "lock.fill",
            title: "Lock",
            subtitle: "Nobody new can join",
            iconBackgroundColor: .colorFillMinimal,
            iconForegroundColor: .colorTextPrimary
        ) {
            if viewModel.isCurrentUserSuperAdmin {
                Toggle("", isOn: Binding(
                    get: { viewModel.isLocked },
                    set: { newValue in
                        if newValue {
                            showingLockConfirmation = true
                        } else {
                            showingLockedInfo = true
                        }
                    }
                ))
                .labelsHidden()
            } else {
                Toggle("", isOn: .constant(viewModel.isLocked))
                    .labelsHidden()
                    .disabled(true)
                    .onTapGesture {
                        if viewModel.isLocked {
                            showingLockedInfo = true
                        }
                    }
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: DesignConstants.Spacing.step4x) {
                            ConversationAvatarView(
                                conversation: viewModel.conversation,
                                conversationImage: viewModel.conversationImage
                            )
                            .frame(width: 160.0, height: 160.0)

                            VStack(spacing: DesignConstants.Spacing.step2x) {
                                Text(viewModel.conversation.computedDisplayName)
                                    .font(.largeTitle.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                    .multilineTextAlignment(.center)
                                if !viewModel.conversationDescription.isEmpty {
                                    Text(viewModel.conversationDescription)
                                        .font(.subheadline)
                                }

                                Button {
                                    presentingEditView = true
                                } label: {
                                    Text("Edit info")
                                        .font(.caption)
                                        .foregroundStyle(.colorTextSecondary)
                                }
                                .buttonStyle(.bordered)
                                .hoverEffect(.lift)
                                .padding(.top, DesignConstants.Spacing.step2x)
                                .sheet(isPresented: $presentingEditView) {
                                    ConversationInfoEditView(viewModel: viewModel, focusCoordinator: focusCoordinator)
                                }
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                .listSectionMargins(.top, 0.0)
                .listSectionSeparator(.hidden)

                Section {
                    NavigationLink {
                        ConversationMembersListView(viewModel: viewModel)
                    } label: {
                        HStack {
                            Text(viewModel.conversation.membersCountString)
                                .foregroundStyle(.colorTextPrimary)
                            Spacer()
                            if viewModel.isFull {
                                Text("Full")
                                    .foregroundStyle(.colorTextSecondary)
                            } else if viewModel.conversation.members.count > 100 {
                                Text("\(Conversation.maxMembers) max")
                                    .foregroundStyle(.colorTextSecondary)
                            }
                        }
                    }
                }

                Section {
                    convoCodeRow

                    lockRow
                } footer: {
                    Text("No one new can join the convo when it's locked")
                        .foregroundStyle(.colorTextSecondary)
                }

                Section {
                    FeatureRowItem(
                        imageName: nil,
                        symbolName: "bell.fill",
                        title: "Notifications",
                        subtitle: nil
                    ) {
                        Toggle("", isOn: $viewModel.notificationsEnabled)
                            .labelsHidden()
                    }

                    FeatureRowItem(
                        imageName: nil,
                        symbolName: "eyeglasses",
                        title: "Peek-a-boo",
                        subtitle: "Blur when people peek"
                    ) {
                        SoonLabel()
                    }

                    FeatureRowItem(
                        imageName: nil,
                        symbolName: "tray.fill",
                        title: "Allow DMs",
                        subtitle: "From group members"
                    ) {
                        SoonLabel()
                    }

                    FeatureRowItem(
                        imageName: nil,
                        symbolName: "faceid",
                        title: "Require FaceID",
                        subtitle: "Or passcode"
                    ) {
                        SoonLabel()
                    }
                } header: {
                    Text("Personal preferences")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                }

                Section {
                    FeatureRowItem(
                        imageName: nil,
                        symbolName: "timer",
                        title: "Disappear",
                        subtitle: "Messages"
                    ) {
                        SoonLabel()
                    }
                } header: {
                    Text("Convo rules")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                }

                Section {
                    HStack {
                        Text("Vanish")
                            .foregroundStyle(.colorTextPrimary)
                        Spacer()
                        SoonLabel()
                    }
                } footer: {
                    Text("Choose when this convo disappears from your device")
                        .foregroundStyle(.colorTextSecondary)
                }
                .disabled(true)

                Section {
                    NavigationLink {
                        EmptyView()
                    } label: {
                        HStack {
                            Text("Permissions")
                                .foregroundStyle(.colorTextPrimary)
                            Spacer()
                            SoonLabel()
                        }
                    }
                    .disabled(true)
                } footer: {
                    Text("Choose who can manage the group")
                        .foregroundStyle(.colorTextSecondary)
                }

                if !ConfigManager.shared.currentEnvironment.isProduction {
                    Section {
                        HStack {
                            Text("Fork status")
                            Spacer()
                            Text(viewModel.conversation.debugInfo.commitLogForkStatus.rawValue)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        HStack {
                            Text("Epoch")
                            Spacer()
                            Text("\(viewModel.conversation.debugInfo.epoch)")
                                .foregroundStyle(.colorTextSecondary)
                        }
                        NavigationLink {
                            DebugLogsTextView(logs: viewModel.conversation.debugInfo.forkDetails)
                        } label: {
                            Text("Fork details")
                        }
                        NavigationLink {
                            DebugLogsTextView(logs: viewModel.conversation.debugInfo.localCommitLog)
                        } label: {
                            Text("Local commit log")
                        }
                        NavigationLink {
                            DebugLogsTextView(logs: viewModel.conversation.debugInfo.remoteCommitLog)
                        } label: {
                            Text("Remote commit log")
                        }
                        if let url = exportedLogsURL {
                            HStack {
                                ShareLink(item: url) {
                                    Text("Share logs")
                                }
                            }
                        }
                    } header: {
                        Text("Debug info")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.colorTextSecondary)
                    }
                    .task {
                        do {
                            let url = try await viewModel.exportDebugLogs()
                            exportedLogsURL = url
                        } catch {
                            Log.error("Failed to export logs for conversation: \(error.localizedDescription)")
                            exportedLogsURL = nil
                        }
                    }
                }

                if viewModel.canRemoveMembers {
                    Section {
                        if let expiresAt = viewModel.scheduledExplosionDate {
                            explosionCountdownRow(expiresAt: expiresAt)

                            let action = {
                                pendingExplosionDate = Date()
                                pendingExplosionLabel = "now"
                                showingExplodeConfirmation = true
                            }
                            Button(action: action) {
                                Text("Explode now")
                                    .foregroundStyle(.colorCaution)
                            }
                        } else {
                            explodeOptions
                        }
                    } footer: {
                        if viewModel.isExplosionScheduled {
                            Text("This convo will be deleted for everyone when the timer runs out")
                                .foregroundStyle(.colorTextSecondary)
                        } else {
                            Text("Choose when this convo will be deleted for everyone")
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                }
            }
            .selfSizingSheet(isPresented: $showingLockConfirmation) {
                LockConvoConfirmationView(
                    onLock: {
                        viewModel.toggleLock()
                        showingLockConfirmation = false
                    },
                    onCancel: {
                        showingLockConfirmation = false
                    }
                )
                .background(.colorBackgroundRaised)
            }
            .selfSizingSheet(isPresented: $showingLockedInfo) {
                LockedConvoInfoView(
                    isCurrentUserSuperAdmin: viewModel.isCurrentUserSuperAdmin,
                    onUnlock: {
                        viewModel.toggleLock()
                        showingLockedInfo = false
                    },
                    onDismiss: {
                        showingLockedInfo = false
                    }
                )
                .background(.colorBackgroundRaised)
            }
            .selfSizingSheet(isPresented: $showingFullInfo) {
                FullConvoInfoView(onDismiss: {
                    showingFullInfo = false
                })
                .background(.colorBackgroundRaised)
            }
            .sheet(isPresented: $showingCustomDatePicker) {
                customDatePickerSheet
            }
            .alert(
                explosionAlertTitle,
                isPresented: $showingExplodeConfirmation
            ) {
                let cancelAction = {
                    pendingExplosionDate = nil
                    pendingExplosionLabel = nil
                }
                Button("Cancel", role: .cancel, action: cancelAction)

                let confirmAction = {
                    if let date = pendingExplosionDate {
                        if date.timeIntervalSinceNow <= 0 {
                            viewModel.explodeConvo()
                        } else {
                            viewModel.scheduleExplosion(at: date)
                        }
                    }
                    pendingExplosionDate = nil
                    pendingExplosionLabel = nil
                }
                Button(pendingExplosionLabel == "now" ? "Explode" : "Start", action: confirmAction)
            } message: {
                Text("The timer cannot be changed or cancelled once it starts.")
            }
        }
    }
}

// MARK: - Explosion Scheduling UI

extension ConversationInfoView {
    @ViewBuilder
    var explodeOptions: some View {
        Menu {
            Button("1 minute") {
                pendingExplosionDate = Date().addingTimeInterval(60)
                pendingExplosionLabel = "1 minute"
                showingExplodeConfirmation = true
            }

            Button("1 hour") {
                pendingExplosionDate = Date().addingTimeInterval(3600)
                pendingExplosionLabel = "1 hour"
                showingExplodeConfirmation = true
            }

            Button("24 hours") {
                pendingExplosionDate = Date().addingTimeInterval(86400)
                pendingExplosionLabel = "24 hours"
                showingExplodeConfirmation = true
            }

            Button("Sunday at midnight") {
                pendingExplosionDate = sundayAtMidnight
                pendingExplosionLabel = "Sunday at midnight"
                showingExplodeConfirmation = true
            }

            Button("Choose date and time") {
                customDate = Date().addingTimeInterval(3600)
                showingCustomDatePicker = true
            }

            Divider()

            Button(role: .destructive) {
                pendingExplosionDate = Date()
                pendingExplosionLabel = "now"
                showingExplodeConfirmation = true
            } label: {
                Text("Explode now")
            }
        } label: {
            HStack {
                Text("Explode")
                    .foregroundStyle(.colorCaution)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var customDatePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "Explode at",
                selection: $customDate,
                in: minimumCustomDate...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) {
                        showingCustomDatePicker = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm) {
                        showingCustomDatePicker = false
                        pendingExplosionDate = customDate
                        pendingExplosionLabel = formatExplosionDuration(for: customDate)
                        showingExplodeConfirmation = true
                    }
                    .tint(.colorBackgroundInverted)
                }
            }
            .navigationTitle("Explode")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(340)])
    }
}

struct DebugLogsTextView: View {
    @State var logs: String
    var body: some View {
        VStack {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text(logs)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding()
                            .id("logs")
                    }
                    .onChange(of: logs) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("logs", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var viewModel: ConversationViewModel = .mock
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    ConversationInfoView(viewModel: viewModel, focusCoordinator: focusCoordinator)
}
