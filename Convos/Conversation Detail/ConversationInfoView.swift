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
    @State private var pendingExplosion: PendingExplosion?
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

    private var minimumCustomDate: Date {
        Date().addingTimeInterval(60)
    }

    private var explosionAlertTitle: String {
        guard let pending = pendingExplosion else {
            return "Explode convo?"
        }
        switch pending {
        case .now:
            return "Explode convo now?"
        case .fixedDate(_, let label):
            return "Explode convo on \(label)?"
        case .delay(_, let label):
            return "Explode convo in \(label)?"
        case .customDate(let date):
            return "Explode convo in \(ExplosionDurationFormatter.format(until: date))?"
        }
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
                    Image(systemName: "burst")
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
                    Text(ExplosionDurationFormatter.countdown(until: expiresAt, from: context.date))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.colorOrange)
                }

                Spacer()
            }
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

                if viewModel.canRemoveMembers {
                    Section {
                        if let expiresAt = viewModel.scheduledExplosionDate {
                            explosionCountdownRow(expiresAt: expiresAt)

                            let action = {
                                pendingExplosion = .now
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
                    pendingExplosion = nil
                }
                Button("Cancel", role: .cancel, action: cancelAction)

                let confirmAction = {
                    guard let pending = pendingExplosion else { return }
                    let date = pending.resolvedDate
                    if date.timeIntervalSinceNow <= 0 {
                        viewModel.explodeConvo()
                    } else {
                        viewModel.scheduleExplosion(at: date)
                    }
                    pendingExplosion = nil
                }
                let confirmLabel = pendingExplosion?.isNow == true ? "Explode" : "Start"
                Button(confirmLabel, role: .destructive, action: confirmAction)
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
                pendingExplosion = .delay(interval: 60, label: "1 minute")
                showingExplodeConfirmation = true
            }

            Button("1 hour") {
                pendingExplosion = .delay(interval: 3600, label: "1 hour")
                showingExplodeConfirmation = true
            }

            Button("24 hours") {
                pendingExplosion = .delay(interval: 86400, label: "24 hours")
                showingExplodeConfirmation = true
            }

            if let sunday = sundayAtMidnight {
                Button("Sunday at midnight") {
                    pendingExplosion = .fixedDate(date: sunday, label: "Sunday at midnight")
                    showingExplodeConfirmation = true
                }
            }

            Button("Choose date and time") {
                customDate = Date().addingTimeInterval(3600)
                showingCustomDatePicker = true
            }

            Divider()

            Button(role: .destructive) {
                pendingExplosion = .now
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
                        pendingExplosion = .customDate(date: customDate)
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

// MARK: - PendingExplosion

private enum PendingExplosion {
    case now
    case delay(interval: TimeInterval, label: String)
    case fixedDate(date: Date, label: String)
    case customDate(date: Date)

    var isNow: Bool {
        if case .now = self { return true }
        return false
    }

    var resolvedDate: Date {
        switch self {
        case .now:
            return Date()
        case .delay(let interval, _):
            return Date().addingTimeInterval(interval)
        case .fixedDate(let date, _), .customDate(let date):
            return date
        }
    }
}

#Preview {
    @Previewable @State var viewModel: ConversationViewModel = .mock
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    ConversationInfoView(viewModel: viewModel, focusCoordinator: focusCoordinator)
}
