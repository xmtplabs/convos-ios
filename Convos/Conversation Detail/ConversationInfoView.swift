import ConvosCore
import SwiftUI

struct FeatureRowItem<AccessoryView: View>: View {
    let imageName: String?
    let symbolName: String
    let title: String
    let subtitle: String?
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
                    .foregroundStyle(.white)
            }
            .frame(width: 40.0, height: 40.0)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(.colorOrange)
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
    @State private var presentingEditView: Bool = false
    @State private var exportedLogsURL: URL?

    private let maxMembersToShow: Int = 6
    private var displayedMembers: [ConversationMember] {
        let sortedMembers = viewModel.conversation.members.sortedByRole()
        return Array(sortedMembers.prefix(maxMembersToShow))
    }
    private var showViewAllMembers: Bool {
        viewModel.conversation.members.count > maxMembersToShow
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
                                Text(viewModel.conversationName.orUntitled)
                                    .font(.largeTitle.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
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
                        Text(viewModel.conversation.membersCountString)
                            .foregroundStyle(.colorTextPrimary)
                    }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ConfigManager.shared.currentEnvironment.relyingPartyIdentifier)
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                            Text(viewModel.invite.urlSlug)
                                .foregroundStyle(.colorTextPrimary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if let inviteURL = viewModel.invite.inviteURL {
                            ShareLink(item: inviteURL) {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(.colorTextSecondary)
                            }
                        }
                    }

                    HStack {
                        Text("Maximum members")

                        Spacer()
                        Text("∞")
                            .foregroundStyle(.colorTextSecondary)
                    }
                    .opacity(0.5)
                    .disabled(true)

                    Toggle(isOn: $viewModel.joinEnabled) {
                        Text("Lock membership")
                    }
                    .opacity(0.5)
                    .disabled(true)
                } header: {
                    Text("Invitations")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
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
                        SoonLabel()
                        // Toggle("", isOn: $viewModel.notificationsEnabled)
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
                        Button {
                            showingExplodeConfirmation = true
                        } label: {
                            Text("Explode now")
                                .foregroundStyle(.colorCaution)
                        }
                        .confirmationDialog("", isPresented: $showingExplodeConfirmation) {
                            Button("Explode", role: .destructive) {
                                viewModel.explodeConvo()
                            }

                            Button("Cancel") {
                                showingExplodeConfirmation = false
                            }
                        }
                    } footer: {
                        Text("Irrecoverably delete the convo for everyone")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                }
            }
        }
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
