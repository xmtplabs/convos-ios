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
    /// Whether the user has touched the draft. Gates the one-time reseed
    /// below: a sheet opened before the global profile finished loading is
    /// seeded from default values, and saving that stale draft would clear
    /// the stored avatar.
    @State private var hasEditedDraft: Bool = false
    /// Drives the sheet's height detent. Seeded with the mode's expected
    /// height and corrected by measurement, so the detent only ever gets
    /// same-kind `.height` updates: a sheet presented at `.medium` (the
    /// selfSizingSheet approach) never re-snaps down to a smaller
    /// `.height`, which left dead space around this content.
    @State private var contentHeight: CGFloat

    private static let privacyAndTermsURL: String = "https://hq.convos.org/privacy-and-terms"

    init(mode: ProfileSetupSheetMode, onSaved: (() -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        let viewModel = ProfileSettingsViewModel.shared
        _displayName = State(initialValue: viewModel.editingDisplayName)
        _profileImage = State(initialValue: viewModel.profileImage)
        _profileImageAssetIdentifier = State(initialValue: viewModel.profileImageAssetIdentifier)
        _contentHeight = State(initialValue: mode.showsTermsRow ? 398.0 : 343.0)
    }

    /// Live preview for the avatar: monogram of the typed name until a
    /// photo is chosen.
    private var previewProfile: Profile {
        ProfileSettings(displayName: displayName, profileImage: profileImage).profile
    }

    private var hasName: Bool {
        !displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var canSave: Bool {
        // Edit mode allows photo-only saves (an empty name falls back to
        // the stored one in saveAndAwait); first launch requires a name.
        (hasName || (mode == .edit && profileImage != nil))
            && (!mode.showsTermsRow || hasAgreedToTerms)
            && !isSaving
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
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.top, DesignConstants.Spacing.step9x)
            .padding(.bottom, DesignConstants.Spacing.step10x)
        }
        .background(.colorBackgroundRaisedSecondary)
        .onChange(of: displayName) { _, _ in
            hasEditedDraft = true
        }
        // Reseed a pristine draft once the global profile load resolves:
        // a sheet opened during a cold launch is seeded from the not yet
        // loaded (default) view model state.
        .onChange(of: profileSettingsViewModel.loadState) { _, newState in
            guard newState == .loaded, !hasEditedDraft else { return }
            displayName = profileSettingsViewModel.editingDisplayName
            profileImage = profileSettingsViewModel.profileImage
            profileImageAssetIdentifier = profileSettingsViewModel.profileImageAssetIdentifier
            // The programmatic writes above flip hasEditedDraft via the
            // displayName onChange; that's fine — one reseed is all that
            // is ever needed.
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { measured in
            contentHeight = measured
        }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.colorBackgroundRaisedSecondary)
        .accessibilityIdentifier("profile-setup-sheet")
        .sheet(isPresented: $isImagePickerPresented) {
            PhotoLibraryPicker(
                preselectedAssetIdentifier: profileImageAssetIdentifier,
                onSelection: { image, assetIdentifier in
                    profileImage = image
                    profileImageAssetIdentifier = assetIdentifier
                    hasEditedDraft = true
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
                    hasEditedDraft = true
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
        // 132pt band per design: 40 above the text block, 28 below.
        .padding(.top, DesignConstants.Spacing.step10x)
        .padding(.bottom, 28.0)
        .background(.colorLava)
    }

    private var nameRow: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Button {
                isImagePickerPresented = true
            } label: {
                // Empty state is person.crop.circle.fill on an inverted
                // circle; a typed name switches to its monogram, a chosen
                // photo to the photo.
                Group {
                    if hasName || profileImage != nil {
                        ProfileAvatarView(
                            profile: previewProfile,
                            profileImage: profileImage,
                            useSystemPlaceholder: false
                        )
                    } else {
                        ZStack {
                            Circle().fill(.colorBackgroundInverted)
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 20.0))
                                .foregroundStyle(.colorTextPrimaryInverted)
                        }
                    }
                }
                .frame(width: 36.0, height: 36.0)
            }
            .accessibilityLabel(profileImage != nil ? "Change photo" : "Choose photo")
            .accessibilityIdentifier("profile-setup-avatar")

            TextField("Name", text: $displayName)
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
                    Image(systemName: "camera.fill")
                }
                .accessibilityLabel("Take photo")
                .accessibilityIdentifier("profile-setup-camera-button")
            }
            .font(.body.weight(.medium))
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
                // 56pt total with RoundedButtonStyle's 16pt vertical padding.
                .frame(height: DesignConstants.Spacing.step6x)
        }
        .convosButtonStyle(.rounded(
            fullWidth: true,
            backgroundColor: canSave ? .colorFillPrimary : .colorFillSecondary
        ))
        .disabled(!canSave)
        .accessibilityIdentifier("profile-setup-save-button")
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            // Snapshot so a failed save doesn't leave the never-persisted
            // draft in the shared view model (it would prefill the next
            // editor session as if it had been stored).
            let previousName = profileSettingsViewModel.editingDisplayName
            let previousImage = profileSettingsViewModel.profileImage
            let previousAssetIdentifier = profileSettingsViewModel.profileImageAssetIdentifier
            do {
                profileSettingsViewModel.editingDisplayName = displayName
                profileSettingsViewModel.profileImage = profileImage
                profileSettingsViewModel.profileImageAssetIdentifier = profileImageAssetIdentifier
                try await profileSettingsViewModel.saveAndAwait()
                QAEvent.emit(.onboarding, "profile_sheet_saved", ["mode": mode == .firstLaunch ? "firstLaunch" : "edit"])
                onSaved?()
                dismiss()
            } catch {
                profileSettingsViewModel.editingDisplayName = previousName
                profileSettingsViewModel.profileImage = previousImage
                profileSettingsViewModel.profileImageAssetIdentifier = previousAssetIdentifier
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
