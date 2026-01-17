import SwiftUI

struct ViewsGuidebookView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                mainScreensHeader

                conversationsViewSection
                conversationViewSection
                newConversationViewSection
                conversationInfoViewSection
                appSettingsViewSection

                sheetViewsHeader

                infoViewSection
                maxedOutInfoViewSection
                errorViewSection
                inviteAcceptedViewSection
                requestPushNotificationsViewSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var mainScreensHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Main Screens")
                .font(.title2.bold())
            Text("Primary app screens and their component hierarchies. These views require ConvosCore dependencies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private var sheetViewsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sheet Views")
                .font(.title2.bold())
            Text("Reusable sheet and modal views that can be displayed standalone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Main Screens

    private var conversationsViewSection: some View {
        ScreenShowcase(
            "ConversationsView",
            description: "Main conversation list with pinned section, filters, and navigation",
            filePath: "Convos/Conversations List/ConversationsView.swift"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ComponentHierarchy(components: [
                    .init(name: "NavigationSplitView", children: [
                        .init(name: "ConversationsListEmptyCTA", note: "Empty state"),
                        .init(name: "PinnedConversationsSection", children: [
                            .init(name: "ConversationsListItem")
                        ]),
                        .init(name: "List", children: [
                            .init(name: "ConversationsListItem", note: "For each conversation")
                        ])
                    ]),
                    .init(name: "Toolbar", children: [
                        .init(name: "ConvosToolbarButton", note: "App settings"),
                        .init(name: "Menu", note: "Filter: All/Unread"),
                        .init(name: "Button", note: "Scan"),
                        .init(name: "Button", note: "Compose")
                    ]),
                    .init(name: "Sheets", children: [
                        .init(name: "AppSettingsView"),
                        .init(name: "NewConversationView"),
                        .init(name: "ExplodeInfoView"),
                        .init(name: "PinLimitInfoView")
                    ])
                ])

                staticConversationsPreview
            }
        }
    }

    private var staticConversationsPreview: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.colorOrange)
                        .frame(width: 24, height: 24)
                    Text("Convos")
                        .font(.callout.weight(.medium))
                }
                Spacer()
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
            }
            .padding()

            VStack(spacing: 0) {
                ForEach(["Ephemeral", "Shane", "Fam"], id: \.self) { name in
                    HStack {
                        Circle()
                            .fill(.colorFillTertiary)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(name)
                                .font(.body.weight(.medium))
                            Text("Last message preview...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("2m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }

            HStack {
                Spacer()
                Image(systemName: "viewfinder")
                Spacer()
                Image(systemName: "square.and.pencil")
                Spacer()
            }
            .padding()
            .foregroundStyle(.colorFillPrimary)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
    }

    private var conversationViewSection: some View {
        ScreenShowcase(
            "ConversationView",
            description: "Conversation detail with messages, input, and onboarding flows",
            filePath: "Convos/Conversation Detail/ConversationView.swift"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ComponentHierarchy(components: [
                    .init(name: "MessagesView", children: [
                        .init(name: "MessagesListView", children: [
                            .init(name: "MessagesGroupView"),
                            .init(name: "MessagesGroupItemView"),
                            .init(name: "TypingIndicatorView"),
                            .init(name: "InviteView")
                        ]),
                        .init(name: "MessagesInputView")
                    ]),
                    .init(name: "ConversationOnboardingView", children: [
                        .init(name: "WhatIsQuicknameView"),
                        .init(name: "SetupQuicknameView"),
                        .init(name: "AddQuicknameView"),
                        .init(name: "InviteAcceptedView"),
                        .init(name: "RequestPushNotificationsView")
                    ]),
                    .init(name: "Sheets", children: [
                        .init(name: "MyInfoView"),
                        .init(name: "ConversationShareView"),
                        .init(name: "ConversationMemberView"),
                        .init(name: "ReactionsDrawerView"),
                        .init(name: "LockedConvoInfoView"),
                        .init(name: "FullConvoInfoView"),
                        .init(name: "ConversationForkedInfoView")
                    ])
                ])

                staticConversationPreview
            }
        }
    }

    private var staticConversationPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left")
                Spacer()
                Text("Ephemeral")
                    .font(.headline)
                Spacer()
                Image(systemName: "square.and.arrow.up")
            }
            .padding()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Text("Hey everyone!")
                        .padding(12)
                        .background(Capsule().fill(.colorBubble))
                }
                HStack {
                    Text("Welcome to the convo")
                        .padding(12)
                        .background(Capsule().fill(.colorBubbleIncoming))
                    Spacer()
                }
            }
            .padding()

            HStack {
                Circle()
                    .fill(.colorFillTertiary)
                    .frame(width: 32, height: 32)
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.colorBorderSubtle, lineWidth: 1)
                    .frame(height: 40)
                    .overlay(
                        Text("Message...")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12),
                        alignment: .leading
                    )
            }
            .padding()
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
    }

    private var newConversationViewSection: some View {
        ScreenShowcase(
            "NewConversationView",
            description: "Create or join a conversation flow",
            filePath: "Convos/Conversation Creation/NewConversationView.swift"
        ) {
            ComponentHierarchy(components: [
                .init(name: "ConversationPresenter"),
                .init(name: "NavigationStack", children: [
                    .init(name: "JoinConversationView", note: "QR scanner mode", children: [
                        .init(name: "QRScannerView")
                    ]),
                    .init(name: "ConversationView", note: "New convo mode")
                ]),
                .init(name: "Sheets", children: [
                    .init(name: "JoinConversationView"),
                    .init(name: "ErrorSheetWithRetry"),
                    .init(name: "InfoView")
                ])
            ])
        }
    }

    private var conversationInfoViewSection: some View {
        ScreenShowcase(
            "ConversationInfoView",
            description: "Conversation settings and member management",
            filePath: "Convos/Conversation Detail/ConversationInfoView.swift"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ComponentHierarchy(components: [
                    .init(name: "NavigationStack", children: [
                        .init(name: "List", children: [
                            .init(name: "ConversationAvatarView"),
                            .init(name: "FeatureRowItem", note: "Multiple instances"),
                            .init(name: "SoonLabel", note: "Coming soon badge"),
                            .init(name: "Toggle", note: "Lock, notifications")
                        ])
                    ]),
                    .init(name: "Navigation Links", children: [
                        .init(name: "ConversationMembersListView"),
                        .init(name: "ConversationInfoEditView")
                    ]),
                    .init(name: "Sheets", children: [
                        .init(name: "LockConvoConfirmationView"),
                        .init(name: "LockedConvoInfoView"),
                        .init(name: "FullConvoInfoView")
                    ])
                ])

                staticConversationInfoPreview
            }
        }
    }

    private var staticConversationInfoPreview: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(.colorFillTertiary)
                .frame(width: 80, height: 80)
            Text("Ephemeral")
                .font(.title2.weight(.semibold))
            Button("Edit info") {}
                .buttonStyle(.bordered)
                .font(.caption)

            VStack(spacing: 0) {
                featureRow(icon: "qrcode", title: "Convo code", subtitle: "convos.org/abc123")
                Divider().padding(.leading, 56)
                featureRow(icon: "lock.fill", title: "Lock", subtitle: "Nobody new can join", hasToggle: true)
                Divider().padding(.leading, 56)
                featureRow(icon: "bell.fill", title: "Notifications", subtitle: nil, hasToggle: true)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.colorFillMinimal))
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
    }

    private func featureRow(icon: String, title: String, subtitle: String?, hasToggle: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(.colorFillMinimal))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasToggle {
                Toggle("", isOn: .constant(false))
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var appSettingsViewSection: some View {
        ScreenShowcase(
            "AppSettingsView",
            description: "App-level settings and user profile",
            filePath: "Convos/App Settings/AppSettingsView.swift"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ComponentHierarchy(components: [
                    .init(name: "NavigationStack", children: [
                        .init(name: "List", children: [
                            .init(name: "ProfileAvatarView"),
                            .init(name: "SoonLabel", note: "Coming soon items")
                        ])
                    ]),
                    .init(name: "Toolbar", children: [
                        .init(name: "ConvosToolbarButton")
                    ]),
                    .init(name: "Navigation Links", children: [
                        .init(name: "MyInfoView"),
                        .init(name: "DebugExportView", note: "Dev only")
                    ]),
                    .init(name: "Sheets", children: [
                        .init(name: "DeleteAllDataView")
                    ])
                ])

                staticAppSettingsPreview
            }
        }
    }

    private var staticAppSettingsPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cancel")
                    .foregroundStyle(.blue)
                Spacer()
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.colorOrange)
                        .frame(width: 24, height: 24)
                    Text("Convos")
                        .font(.callout.weight(.medium))
                }
                .padding(8)
                .background(Capsule().fill(.colorFillMinimal))
                Spacer()
                Text("     ")
            }
            .padding()

            VStack(spacing: 0) {
                settingsRow(title: "My info", trailing: "Somebody")
                Divider().padding(.leading, 16)
                settingsRow(title: "Customize new convos", trailing: "Soon")
                Divider().padding(.leading, 16)
                settingsRow(title: "Notifications", trailing: "Soon")
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.colorFillMinimal))
            .padding()
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
    }

    private func settingsRow(title: String, trailing: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(trailing)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    // MARK: - Sheet Views

    private var infoViewSection: some View {
        ComponentShowcase(
            "InfoView",
            description: "Generic info sheet with title, description, and dismiss button"
        ) {
            InfoView(
                title: "Invalid invite",
                description: "Looks like this invite isn't active anymore.",
                onDismiss: nil
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var maxedOutInfoViewSection: some View {
        ComponentShowcase(
            "MaxedOutInfoView",
            description: "Warning shown when user reaches max conversation limit"
        ) {
            MaxedOutInfoView(maxNumberOfConvos: 20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.background)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var errorViewSection: some View {
        ComponentShowcase(
            "ErrorView",
            description: "Error state view with optional retry action"
        ) {
            VStack(spacing: 16) {
                Text("With Retry:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ErrorView(error: SampleError.networkError, onRetry: {})
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.background)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Without Retry:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ErrorView(error: SampleError.genericError, onRetry: nil)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.background)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var inviteAcceptedViewSection: some View {
        ComponentShowcase(
            "InviteAcceptedView",
            description: "Success confirmation when an invite is accepted"
        ) {
            InviteAcceptedView()
        }
    }

    private var requestPushNotificationsViewSection: some View {
        ComponentShowcase(
            "RequestPushNotificationsView",
            description: "Push notification permission request with multiple states"
        ) {
            VStack(spacing: 16) {
                Text("Request State:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                RequestPushNotificationsView(
                    isWaitingForInviteAcceptance: false,
                    permissionState: .request,
                    enableNotifications: {},
                    openSettings: {}
                )

                Text("Enabled State:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                RequestPushNotificationsView(
                    isWaitingForInviteAcceptance: false,
                    permissionState: .enabled,
                    enableNotifications: {},
                    openSettings: {}
                )

                Text("Denied State:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                RequestPushNotificationsView(
                    isWaitingForInviteAcceptance: false,
                    permissionState: .denied,
                    enableNotifications: {},
                    openSettings: {}
                )
            }
        }
    }
}

// MARK: - Supporting Views

struct ScreenShowcase<Content: View>: View {
    let title: String
    let description: String
    let filePath: String
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        description: String,
        filePath: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.description = description
        self.filePath = filePath
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                CodeNameLabel(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(filePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            content()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .fill(.colorBackgroundRaised)
        )
    }
}

struct ComponentHierarchy: View {
    let components: [ComponentNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(components) { node in
                ComponentNodeView(node: node, depth: 0)
            }
        }
        .font(.caption.monospaced())
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(.colorFillMinimal))
    }
}

struct ComponentNode: Identifiable {
    let id: UUID = UUID()
    let name: String
    var note: String?
    var children: [ComponentNode] = []

    init(name: String, note: String? = nil, children: [ComponentNode] = []) {
        self.name = name
        self.note = note
        self.children = children
    }
}

struct ComponentNodeView: View {
    let node: ComponentNode
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(String(repeating: "  ", count: depth))
                if depth > 0 {
                    Text("├─")
                        .foregroundStyle(.tertiary)
                }
                Text(node.name)
                    .foregroundStyle(.colorFillPrimary)
                if let note = node.note {
                    Text("// \(note)")
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(node.children) { child in
                ComponentNodeView(node: child, depth: depth + 1)
            }
        }
    }
}

private enum SampleError: Error, LocalizedError {
    case networkError
    case genericError

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Unable to connect. Please check your internet connection."
        case .genericError:
            return "Something went wrong."
        }
    }
}

#Preview {
    NavigationStack {
        ViewsGuidebookView()
            .navigationTitle("Views")
    }
}
