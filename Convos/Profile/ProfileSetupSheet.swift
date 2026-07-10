import ConvosCore
import SwiftUI

/// The two contexts the profile setup sheet is shown in. Both edit the
/// global profile through `ProfileSettingsViewModel`; they differ only in
/// chrome: the first-launch variant asks for terms consent and invites the
/// user in, the edit variant is a plain save.
enum ProfileSetupSheetMode {
    /// Shown once on first launch (no iCloud key backups, no pairing sheet).
    case firstLaunch
    /// Shown from Settings > My info and from the user's own profile in a
    /// conversation.
    case edit

    var ctaTitle: String {
        switch self {
        case .firstLaunch: "Come in"
        case .edit: "Save"
        }
    }

    var showsTermsRow: Bool {
        self == .firstLaunch
    }
}

/// "Hello / My name is" profile setup sheet: lava header, a name field with
/// a live avatar (monogram until a photo is chosen) and photo-library /
/// camera pickers, and a save CTA. Designed to be presented with
/// `selfSizingSheet`.
struct ProfileSetupSheet: View {
    let mode: ProfileSetupSheetMode
    var onSaved: (() -> Void)?

    private let profileSettingsViewModel: ProfileSettingsViewModel = .shared

    // Local draft of the edit, copied into `ProfileSettingsViewModel` only on
    // save. Binding the fields directly to the shared view model loses
    // in-flight edits: its profile observation re-applies the canonical
    // (initially nil) global profile whenever the inbox re-emits, which on a
    // fresh install happens while this sheet is on screen.
    @State private var displayName: String
    @State private var profileImage: UIImage?
    @State private var profileImageAssetIdentifier: String?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var isImagePickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false
    @State private var hasAgreedToTerms: Bool = true
    @State private var isSaving: Bool = false

    private static let privacyAndTermsURL: String = "https://hq.convos.org/privacy-and-terms"

    init(mode: ProfileSetupSheetMode, onSaved: (() -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        let viewModel = ProfileSettingsViewModel.shared
        _displayName = State(initialValue: viewModel.editingDisplayName)
        _profileImage = State(initialValue: viewModel.profileImage)
        _profileImageAssetIdentifier = State(initialValue: viewModel.profileImageAssetIdentifier)
    }

    /// Live preview for the avatar: monogram of the typed name until a
    /// photo is chosen.
    private var previewProfile: Profile {
        ProfileSettings(displayName: displayName, profileImage: profileImage).profile
    }

    private var canSave: Bool {
        let hasName = !displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return hasName && (!mode.showsTermsRow || hasAgreedToTerms) && !isSaving
    }

    var body: some View {
        VStack(spacing: 0.0) {
            header

            VStack(spacing: DesignConstants.Spacing.step6x) {
                nameRow
                if mode.showsTermsRow {
                    termsRow
                }
                saveButton
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.top, DesignConstants.Spacing.step16x)
            .padding(.bottom, DesignConstants.Spacing.step10x)
        }
        .background(.colorBackgroundRaisedSecondary)
        .accessibilityIdentifier("profile-setup-sheet")
        .sheet(isPresented: $isImagePickerPresented) {
            PhotoLibraryPicker(
                preselectedAssetIdentifier: profileImageAssetIdentifier,
                onSelection: { image, assetIdentifier in
                    profileImage = image
                    profileImageAssetIdentifier = assetIdentifier
                    isImagePickerPresented = false
                },
                onCancel: { isImagePickerPresented = false }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPickerView(
                onImageCaptured: { image in
                    profileImage = image
                    profileImageAssetIdentifier = nil
                },
                onVideoCaptured: nil
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text("Hello")
                .font(.system(size: 40.0))
                .tracking(-1)
            Text("My name is")
                .font(.subheadline)
        }
        .foregroundStyle(.colorTextPrimaryInverted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step10x)
        .background(.colorLava)
    }

    private var nameRow: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Button {
                isImagePickerPresented = true
            } label: {
                ProfileAvatarView(
                    profile: previewProfile,
                    profileImage: profileImage,
                    useSystemPlaceholder: false
                )
                .frame(width: 36.0, height: 36.0)
            }
            .accessibilityLabel(profileImage != nil ? "Change photo" : "Choose photo")
            .accessibilityIdentifier("profile-setup-avatar")

            TextField(profileSettingsViewModel.exampleDisplayName, text: $displayName)
                .font(.body)
                .submitLabel(.done)
                .accessibilityIdentifier("profile-setup-name-field")

            HStack(spacing: DesignConstants.Spacing.step5x) {
                Button {
                    isImagePickerPresented = true
                } label: {
                    Image(systemName: "photo")
                }
                .accessibilityLabel("Choose photo from library")
                .accessibilityIdentifier("profile-setup-photo-button")

                Button {
                    isCameraPresented = true
                } label: {
                    Image(systemName: "camera")
                }
                .accessibilityLabel("Take photo")
                .accessibilityIdentifier("profile-setup-camera-button")
            }
            .font(.body)
            .foregroundStyle(.colorTextSecondary)
            .padding(.trailing, DesignConstants.Spacing.step2x)
        }
        .padding(DesignConstants.Spacing.step2x)
        .background(Capsule().fill(.colorBackgroundRaised))
    }

    private var termsRow: some View {
        HStack(spacing: DesignConstants.Spacing.step4x) {
            Button {
                guard let url = URL(string: Self.privacyAndTermsURL) else { return }
                openURL(url)
            } label: {
                Text("I agree to \(Text("Convos Privacy & Terms").underline())")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
            .accessibilityIdentifier("profile-setup-terms-link")

            Toggle("I agree to Convos Privacy & Terms", isOn: $hasAgreedToTerms)
                .labelsHidden()
                .tint(.colorGreen)
                .accessibilityIdentifier("profile-setup-terms-toggle")
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text(mode.ctaTitle)
                .font(.body)
                .frame(maxWidth: .infinity)
                .frame(height: DesignConstants.Spacing.step10x)
        }
        .convosButtonStyle(.rounded(fullWidth: true))
        .disabled(!canSave)
        .accessibilityIdentifier("profile-setup-save-button")
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                profileSettingsViewModel.editingDisplayName = displayName
                profileSettingsViewModel.profileImage = profileImage
                profileSettingsViewModel.profileImageAssetIdentifier = profileImageAssetIdentifier
                try await profileSettingsViewModel.saveAndAwait()
                QAEvent.emit(.onboarding, "profile_sheet_saved", ["mode": mode == .firstLaunch ? "firstLaunch" : "edit"])
                onSaved?()
                dismiss()
            } catch {
                Log.error("Failed saving profile from setup sheet: \(error)")
            }
        }
    }
}

#Preview("First launch") {
    Color.clear
        .selfSizingSheet(isPresented: .constant(true)) {
            ProfileSetupSheet(mode: .firstLaunch)
        }
}

#Preview("Edit") {
    Color.clear
        .selfSizingSheet(isPresented: .constant(true)) {
            ProfileSetupSheet(mode: .edit)
        }
}
