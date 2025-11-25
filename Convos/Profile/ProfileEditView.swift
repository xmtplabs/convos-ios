import ConvosCore
import PhotosUI
import SwiftUI

struct ProfileEditView: View {
    @Binding var profile: Profile
    @Binding var profileImage: UIImage?
    @Binding var editingDisplayName: String
    @Binding var saveDisplayNameAsQuickname: Bool

    @Bindable var quicknameSettings: QuicknameSettingsViewModel

    let showsQuicknameToggle: Bool
    let showsCancelButton: Bool

    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isImagePickerPresented: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: DesignConstants.Spacing.step6x) {
                            ProfileAvatarView(
                                profile: profile,
                                profileImage: profileImage
                            )
                            .frame(width: 160.0, height: 160.0)

                            ImagePickerButton(
                                currentImage: $profileImage,
                                isPickerPresented: $isImagePickerPresented,
                                showsCurrentImage: false,
                                symbolSize: 20.0
                            )
                            .frame(width: 44.0, height: 44.0)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
                .listRowSpacing(0.0)
                .listRowInsets(.all, DesignConstants.Spacing.step2x)
                .listSectionMargins(.top, 0.0)
                .listSectionSeparator(.hidden)

                Section {
                    TextField("Somebody", text: $editingDisplayName)
                        .scrollDismissesKeyboard(.interactively)
                }

                if showsQuicknameToggle {
                    Section {
                        Toggle(isOn: $saveDisplayNameAsQuickname) {
                            Text("Use as quickname")
                                .foregroundStyle(.colorTextPrimary)
                        }
                    } footer: {
                        Text("Quickly add this Name and Pic to new convos. You’ll still start anonymous.")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }

//                Section {
//                    NavigationLink {
//                        QuicknameRandomizerSettingsView(quicknameSettings: quicknameSettings)
//                    } label: {
//                        VStack(alignment: .leading) {
//                            Text("Randomizer")
//                            Text(quicknameSettings.quicknameSettings.randomizerSummary)
//                                .foregroundStyle(.colorTextSecondary)
//                        }
//                    }
//                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .contentMargins(.top, 0.0)
            .listSectionMargins(.all, 0.0)
            .listRowInsets(.all, 0.0)
            .listSectionSpacing(DesignConstants.Spacing.step6x)
            .toolbar {
                if showsCancelButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .cancel) {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm) {
                        onConfirm()
                    }
                    .tint(.colorBackgroundInverted)
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var viewModel: MyProfileViewModel = .mock

    return ProfileEditView(
        profile: .constant(viewModel.profile),
        profileImage: $viewModel.profileImage,
        editingDisplayName: $viewModel.editingDisplayName,
        saveDisplayNameAsQuickname: $viewModel.saveDisplayNameAsQuickname,
        quicknameSettings: viewModel.quicknameSettings,
        showsQuicknameToggle: false,
        showsCancelButton: false
    ) {
        // confirm
    }
}
