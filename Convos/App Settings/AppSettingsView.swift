import SwiftUI

struct ConvosToolbarButton: View {
    let padding: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image("convosOrangeIcon")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.colorFillPrimary)
                    .frame(width: 16.0, height: 20.0)
                    .frame(width: 24.0, height: 24.0)
                    .accessibilityHidden(true)

                Text("Convos")
                    .font(.body)
                    .foregroundStyle(.colorFillPrimary)
                    .padding(.trailing, DesignConstants.Spacing.stepX)
            }
            .padding(padding ? DesignConstants.Spacing.step2x : 0)
        }
        .accessibilityIdentifier("convos-logo-button")
    }
}

// swiftlint:disable force_unwrapping

struct AppSettingsView: View {
    @Bindable var viewModel: AppSettingsViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    let onDeleteAllData: () -> Void
    @State private var showingDeleteAllDataConfirmation: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                        Text("Convos")
                            .font(.system(size: 40, weight: .bold))
                            .tracking(-1)
                            .foregroundStyle(.colorTextPrimary)
                        Text("Private chat for the AI world")
                            .font(.subheadline)
                            .foregroundStyle(.colorTextPrimary)
                    }
                    .padding(.horizontal, DesignConstants.Spacing.step2x)
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
                .listRowSpacing(0.0)
                .listRowInsets(.all, DesignConstants.Spacing.step2x)
                .listSectionMargins(.top, 0.0)
                .listSectionSeparator(.hidden)

                Section {
                    NavigationLink {
                        MyInfoView(
                            profile: .constant(.empty()),
                            profileImage: .constant(nil),
                            editingDisplayName: .constant(""),
                            quicknameViewModel: quicknameViewModel,
                            showsCancelButton: false,
                            showsProfile: false,
                            showsUseQuicknameButton: false,
                            canEditQuickname: true
                        ) { _ in
                        }
                    } label: {
                        HStack {
                            Image(systemName: "lanyardcard.fill")
                                .foregroundStyle(.colorTextPrimary)

                            Text("My info")
                                .foregroundStyle(.colorTextPrimary)

                            Spacer()

                            if !quicknameViewModel.quicknameSettings.isDefault {
                                Text(quicknameViewModel.editingDisplayName)
                                    .foregroundStyle(.colorTextSecondary)

                                ProfileAvatarView(
                                    profile: quicknameViewModel.profile,
                                    profileImage: quicknameViewModel.profileImage,
                                    useSystemPlaceholder: false
                                )
                                .frame(width: 16.0, height: 16.0)
                            }
                        }
                    }
                } footer: {
                    Text("Private unless you choose to share")
                }

                Section {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Text("Customize new convos")
                            .foregroundStyle(.colorTextTertiary)

                        Spacer()

                        SoonLabel()
                    }
                    .listRowInsets(.init(top: 0, leading: DesignConstants.Spacing.step4x, bottom: 0, trailing: 10.0))

                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Text("Notifications")
                            .foregroundStyle(.colorTextTertiary)

                        Spacer()

                        SoonLabel()
                    }
                    .listRowInsets(.init(top: 0, leading: DesignConstants.Spacing.step4x, bottom: 0, trailing: 10.0))
                }
                .listRowSeparatorTint(.colorBorderSubtle)

                Section {
                    Button {
                        openURL(URL(string: "https://xmtp.org")!)
                    } label: {
                        NavigationLink {
                            EmptyView()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 0.0) {
                                Text("Secured by ")
                                Image("xmtpIcon")
                                    .renderingMode(.template)
                                    .foregroundStyle(.colorTextPrimary)
                                    .padding(.trailing, 1.0)
                                Text("XMTP")
                            }
                            .foregroundStyle(.colorTextPrimary)
                        }
                    }
                    .foregroundStyle(.colorTextPrimary)

                    Button {
                        openURL(URL(string: "https://hq.convos.org/privacy-and-terms")!)
                    } label: {
                        NavigationLink("Privacy & Terms", destination: EmptyView())
                    }
                    .foregroundStyle(.colorTextPrimary)

                    Button {
                        sendFeedback()
                    } label: {
                        Text("Send feedback")
                    }
                    .foregroundStyle(.colorTextPrimary)

                    if !ConfigManager.shared.currentEnvironment.isProduction {
                        NavigationLink {
                            DebugExportView(environment: ConfigManager.shared.currentEnvironment)
                        } label: {
                            Text("Debug")
                        }
                        .foregroundStyle(.colorTextPrimary)
                    }
                } footer: {
                    HStack {
                        Text("Made in the open by XMTP Labs")
                        Spacer()
                        Text("V\(Bundle.appVersion)")
                            .foregroundStyle(.colorTextTertiary)
                    }
                    .foregroundStyle(.colorTextSecondary)
                }
                .listRowSeparatorTint(.colorBorderSubtle)

                Section {
                    Button(role: .destructive) {
                        showingDeleteAllDataConfirmation = true
                    } label: {
                        Text("Delete all app data")
                    }
                    .accessibilityLabel("Delete all app data")
                    .accessibilityHint("Permanently deletes all conversations and your quickname")
                    .accessibilityIdentifier("delete-all-data-button")
                    .selfSizingSheet(isPresented: $showingDeleteAllDataConfirmation) {
                        DeleteAllDataView(
                            viewModel: viewModel,
                            onComplete: {
                                dismiss()
                                onDeleteAllData()
                            }
                        )
                        .interactiveDismissDisabled(viewModel.isDeleting)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .contentMargins(.top, 0.0)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .principal) {
                    ConvosToolbarButton(padding: true) {}
                        .glassEffect(.regular.tint(.colorBackgroundSurfaceless).interactive(), in: Capsule())
                        .disabled(true)
                }
            }
        }
    }

    private func sendFeedback() {
        let email = "convos@ephemerahq.com"
        let subject = "Convos Feedback"
        let mailtoString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject)"

        if let mailtoURL = URL(string: mailtoString) {
            openURL(mailtoURL)
        }
    }
}

// swiftlint:enable force_unwrapping

#Preview {
    let quicknameViewModel = QuicknameSettingsViewModel.shared
    NavigationStack {
        AppSettingsView(
            viewModel: .mock,
            quicknameViewModel: quicknameViewModel,
            onDeleteAllData: {}
        )
    }
}
