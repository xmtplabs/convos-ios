import ConvosCore
import PhotosUI
import SwiftUI

struct MyInfoView: View {
    @Binding var profile: Profile
    @Binding var profileImage: UIImage?
    @Binding var editingDisplayName: String

    @Bindable var quicknameViewModel: QuicknameSettingsViewModel

    let showsCancelButton: Bool
    let showsProfile: Bool
    let showsUseQuicknameButton: Bool
    let canEditQuickname: Bool

    let onUseQuickname: (QuicknameSettings) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isImagePickerPresented: Bool = false
    @State private var didUseQuickname: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                        Text("My info")
                            .font(.system(size: 40, weight: .bold))
                            .tracking(-1)
                            .foregroundStyle(.colorTextPrimary)

                        Text("Private unless you choose to share it")
                            .font(.subheadline)
                            .foregroundStyle(.colorTextPrimary)
                            .padding(.bottom, DesignConstants.Spacing.stepX)

                        Text("Your info is stored on your device only.")
                            .font(.footnote)
                            .foregroundStyle(.colorTextSecondary)
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

                                Text(
                                    editingDisplayName.isEmpty ? "Somebody" : editingDisplayName
                                )
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

                Section {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        if canEditQuickname {
                            ImagePickerButton(
                                currentImage: $quicknameViewModel.profileImage,
                                isPickerPresented: $isImagePickerPresented,
                                showsCurrentImage: true,
                                symbolSize: 12.0,
                                symbolName: "photo.fill"
                            )
                            .frame(width: 32.0, height: 32.0)

                            TextField("Somebody", text: $quicknameViewModel.editingDisplayName)
                                .scrollDismissesKeyboard(.interactively)
                                .submitLabel(.done)
                        } else {
                            ProfileAvatarView(
                                profile: quicknameViewModel.profile,
                                profileImage: quicknameViewModel.profileImage,
                                useSystemPlaceholder: false
                            )
                            .frame(width: 32.0, height: 32.0)

                            Text(
                                quicknameViewModel.editingDisplayName.isEmpty ? "Somebody" : quicknameViewModel.editingDisplayName
                            )
                            .foregroundStyle(.colorTextPrimary)
                        }

                        Spacer()

                        if showsUseQuicknameButton {
                            Button {
                                withAnimation {
                                    didUseQuickname = true
                                }
                                onUseQuickname(quicknameViewModel.quicknameSettings)
                            } label: {
                                ZStack {
                                    Text("Use")
                                        .font(.body)
                                        .foregroundStyle(.colorTextPrimaryInverted)
                                        .padding(.horizontal, 10.0)
                                        .padding(.vertical, 6.0)
                                        .opacity(didUseQuickname ? 0.0 : 1.0)

                                    if didUseQuickname {
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
                            .disabled(didUseQuickname)
                            .background(Capsule().fill(.colorFillPrimary))
                            .accessibilityLabel(didUseQuickname ? "Quickname applied" : "Use quickname")
                            .accessibilityIdentifier("use-quickname-button")
                        }
                    }
                    .buttonStyle(.borderless)
                    .listRowInsets(.init(top: DesignConstants.Spacing.step2x, leading: 10.0, bottom: DesignConstants.Spacing.step2x, trailing: 10.0))
                } footer: {
                    Text("Quickname: a name and pic to use quick")
                        .foregroundStyle(.colorTextSecondary)
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
                if canEditQuickname {
                    quicknameViewModel.save()
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
    @Previewable @State var quicknameViewModel: QuicknameSettingsViewModel = .shared

    MyInfoView(
        profile: .constant(viewModel.profile),
        profileImage: $viewModel.profileImage,
        editingDisplayName: $viewModel.editingDisplayName,
        quicknameViewModel: quicknameViewModel,
        showsCancelButton: false,
        showsProfile: true,
        showsUseQuicknameButton: true,
        canEditQuickname: false
    ) { _ in
    }
}
