import ConvosCore
import PhotosUI
import SwiftUI

struct MyInfoView: View {
    @Binding var profile: Profile
    @Binding var profileImage: UIImage?
    @Binding var editingDisplayName: String

    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel

    let showsCancelButton: Bool
    let showsProfile: Bool
    let showsUseProfileButton: Bool
    let canEditProfile: Bool

    let onUseProfile: (ProfileSettings) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isImagePickerPresented: Bool = false
    @State private var didUseProfile: Bool = false

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("My info")
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-1)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.top, DesignConstants.Spacing.step2x)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
        .listRowSpacing(0.0)
        .listRowInsets(.all, DesignConstants.Spacing.step2x)
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }

    @ViewBuilder
    private var profileSection: some View {
        if showsProfile {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        ProfileAvatarView(
                            profile: profile,
                            profileImage: profileImage,
                            useSystemPlaceholder: false
                        )
                        .frame(width: 16.0, height: 16.0)

                        Text(editingDisplayName.isEmpty ? "Somebody" : editingDisplayName)
                            .font(.body)
                            .foregroundStyle(.colorTextPrimary)

                        Spacer()
                    }

                    Text("How you appear in this convo")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection

                profileSection

                Section {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        if canEditProfile {
                            ImagePickerButton(
                                currentImage: $profileSettingsViewModel.profileImage,
                                isPickerPresented: $isImagePickerPresented,
                                currentImageAssetIdentifier: $profileSettingsViewModel.profileImageAssetIdentifier,
                                showsCurrentImage: true,
                                symbolSize: 12.0,
                                symbolName: "photo.fill"
                            )
                            .frame(width: 32.0, height: 32.0)
                            .accessibilityIdentifier("profile-image-picker")

                            TextField("Somebody", text: $profileSettingsViewModel.editingDisplayName)
                                .scrollDismissesKeyboard(.interactively)
                                .submitLabel(.done)
                                .accessibilityIdentifier("profile-display-name-field")
                        } else {
                            ProfileAvatarView(
                                profile: profileSettingsViewModel.profile,
                                profileImage: profileSettingsViewModel.profileImage,
                                useSystemPlaceholder: false
                            )
                            .frame(width: 32.0, height: 32.0)

                            Text(
                                profileSettingsViewModel.editingDisplayName.isEmpty ? "Somebody" : profileSettingsViewModel.editingDisplayName
                            )
                            .foregroundStyle(.colorTextPrimary)
                        }

                        Spacer()

                        if showsUseProfileButton {
                            Button {
                                withAnimation {
                                    didUseProfile = true
                                }
                                onUseProfile(profileSettingsViewModel.profileSettings)
                            } label: {
                                ZStack {
                                    Text("Use")
                                        .font(.body)
                                        .foregroundStyle(.colorTextPrimaryInverted)
                                        .padding(.horizontal, 10.0)
                                        .padding(.vertical, 6.0)
                                        .opacity(didUseProfile ? 0.0 : 1.0)

                                    if didUseProfile {
                                        Image(systemName: "checkmark")
                                            .symbolEffect(.bounce, options: .nonRepeating)
                                            .font(.body)
                                            .foregroundStyle(.colorTextPrimaryInverted)
                                            .padding(.horizontal, 10.0)
                                            .padding(.vertical, 6.0)
                                    }
                                }
                                .frame(minHeight: DesignConstants.Spacing.step8x)
                            }
                            .disabled(didUseProfile)
                            .background(Capsule().fill(.colorFillPrimary))
                            .accessibilityLabel(didUseProfile ? "Profile applied" : "Use profile")
                            .accessibilityIdentifier("use-profile-button")
                        }
                    }
                    .buttonStyle(.borderless)
                    .listRowInsets(.init(top: DesignConstants.Spacing.step2x, leading: 10.0, bottom: DesignConstants.Spacing.step2x, trailing: 10.0))
                }

                Section {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Text("Social names · Phone number")
                            .font(.body)
                            .foregroundStyle(.colorTextTertiary)

                        Spacer()

                        SoonLabel()
                    }
                    .padding(.vertical, 10.0)
                    .listRowInsets(.init(top: 0, leading: DesignConstants.Spacing.step4x, bottom: 0, trailing: 10.0))
                } footer: {
                    Text("Verified info")
                        .foregroundStyle(.colorTextSecondary)
                }

                Section {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Text("Human · Age")
                            .font(.body)
                            .foregroundStyle(.colorTextTertiary)

                        Spacer()

                        SoonLabel()
                    }
                    .padding(.vertical, 10.0)
                    .listRowInsets(.init(top: 0, leading: DesignConstants.Spacing.step4x, bottom: 0, trailing: 10.0))
                } footer: {
                    Text("Proofs")
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .contentMargins(.top, 0.0)
            .listSectionMargins(.all, 0.0)
            .listRowInsets(.all, 0.0)
            .listSectionSpacing(DesignConstants.Spacing.step6x)
            .onDisappear {
                if canEditProfile {
                    profileSettingsViewModel.save()
                }
            }
            .toolbar {
                if showsCancelButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .cancel) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var viewModel: MyProfileViewModel = .mock
    @Previewable @State var profileSettingsViewModel: ProfileSettingsViewModel = .shared

    MyInfoView(
        profile: .constant(viewModel.profile),
        profileImage: $viewModel.profileImage,
        editingDisplayName: $viewModel.editingDisplayName,
        profileSettingsViewModel: profileSettingsViewModel,
        showsCancelButton: false,
        showsProfile: true,
        showsUseProfileButton: true,
        canEditProfile: false
    ) { _ in
    }
}
