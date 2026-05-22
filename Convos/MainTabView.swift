import PhotosUI
import SwiftUI

/// Root tab shell for the app. Hosts the existing `ConversationsView` under
/// the "Chats" tab, a placeholder `StuffTabView` under "Stuff", and an
/// iOS 26 `Tab(role: .search)` for the search affordance that floats at
/// the bottom trailing edge.
///
/// The app indicator (leading) and compose button (trailing) live inside
/// each tab's own top bar — not on this shell — because each tab's chrome
/// is contextual (Chats has compose, Stuff and Search don't). See
/// `ConversationsView` for the Chats top-bar wiring.
struct MainTabView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel

    /// Drives the `AssistantBuilderBar` between expanded (full pill) and
    /// collapsed (avatar circle) states. Defaults to expanded on app
    /// launch — the inner tab content flips this to false when its list
    /// scrolls past the top, and back to true when the list returns near
    /// the top. State lives here so a tab swap doesn't reset the bar's
    /// position.
    @State private var isBuilderBarExpanded: Bool = true
    /// Photo / camera / voice-memo entry points for the
    /// `AssistantBuilderBar`. Tapping the photo or camera icon presents
    /// the matching picker first; only once the user has actually picked
    /// (or captured) media do we open the builder sheet, so abandoning
    /// the picker leaves the user where they were. Voice memo skips the
    /// picker and opens the builder directly in recording mode.
    @State private var isPhotoPickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    /// Drives the app-settings sheet that the `AppIndicatorPill` (in
    /// every tab that renders one) presents on tap. Lives at this shell
    /// level so both the Chats and Stuff tabs share a single sheet
    /// instance — the alternative (a sheet per tab) would mean tapping
    /// the pill on the wrong tab wouldn't work after a tab swap and
    /// would duplicate the `AppSettingsView` view-model wiring.
    @State private var presentingAppSettings: Bool = false
    /// Shared namespace for the assistant-builder bar -> sheet zoom
    /// transition and the app-settings pill -> sheet zoom transition.
    /// The bar / pill apply
    /// `.matchedTransitionSource(id: ..., in: namespace)` and the
    /// matching sheet uses `.navigationTransition(.zoom(sourceID: ..., in: namespace))`
    /// to get the same source-to-sheet morph the compose button uses in
    /// `ConversationsView`.
    @Namespace private var namespace: Namespace.ID

    private var appIndicatorContext: AppIndicatorContext {
        AppIndicatorContext(
            profileImage: profileSettingsViewModel.profileImage,
            transitionNamespace: namespace,
            transitionId: Constant.appSettingsTransitionId,
            onTap: { presentingAppSettings = true }
        )
    }

    /// `true` once a conversation has been pushed onto the Chats tab's
    /// navigation stack. Hides the builder bar (via the safe-area inset
    /// conditional) and the tab bar so the conversation detail can use
    /// the full screen. Bound to `conversationsViewModel` because the
    /// selection model lives there.
    private var isConversationSelected: Bool {
        conversationsViewModel.selectedConversationViewModel != nil
    }

    var body: some View {
        TabView {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill") {
                ConversationsView(
                    viewModel: conversationsViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    appIndicatorContext: appIndicatorContext,
                    sidebarBottomAccessory: AnyView(assistantBuilderBar)
                )
                .toolbar(isConversationSelected ? .hidden : .automatic, for: .tabBar)
            }

            Tab("Stuff", systemImage: "square.grid.2x2.fill") {
                StuffTabView(
                    appIndicatorContext: appIndicatorContext,
                    conversationsViewModel: conversationsViewModel
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    assistantBuilderBar
                }
            }

            Tab(role: .search) {
                SearchTabView()
            }
        }
        .sheet(item: $conversationsViewModel.assistantBuilderViewModel) { builderViewModel in
            AssistantBuilderView(
                viewModel: builderViewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
            .background(.colorBackgroundSurfaceless)
            .presentationSizing(.page)
            .navigationTransition(
                .zoom(sourceID: Constant.builderTransitionId, in: namespace)
            )
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotos,
            maxSelectionCount: maxPendingMediaAttachments,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotos) { _, newValue in
            handleSelectedPhotosChanged(to: newValue)
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPickerView(
                onImageCaptured: handleCameraImageCaptured,
                onVideoCaptured: handleCameraVideoCaptured
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $presentingAppSettings) {
            AppSettingsView(
                viewModel: conversationsViewModel.appSettingsViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                session: conversationsViewModel.session,
                onDeleteAllData: conversationsViewModel.deleteAllData
            )
            .navigationTransition(
                .zoom(sourceID: Constant.appSettingsTransitionId, in: namespace)
            )
            .interactiveDismissDisabled(conversationsViewModel.appSettingsViewModel.isDeleting)
        }
        .sheet(item: $conversationsViewModel.newConversationViewModel) { newConvoViewModel in
            NewConversationView(
                viewModel: newConvoViewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
            .background(.colorBackgroundSurfaceless)
            .presentationSizing(.page)
            .navigationTransition(
                .zoom(sourceID: Constant.composerTransitionId, in: namespace)
            )
        }
    }

    /// The bar is duplicated as an inset on each tab that wants it (Chats,
    /// Stuff) instead of using `.tabViewBottomAccessory` — the accessory
    /// modifier caps its content height too tightly for the design's
    /// expanded glass pill (avatar + label + three icon buttons). Each
    /// instance reads from / writes to the shared `isBuilderBarExpanded`
    /// state on `MainTabView`, so swapping tabs preserves the bar's
    /// position.
    @ViewBuilder
    private var assistantBuilderBar: some View {
        AssistantBuilderBar(
            isExpanded: isBuilderBarExpanded,
            onTap: openBuilder,
            onTapPhotos: { isPhotoPickerPresented = true },
            onTapCamera: { isCameraPresented = true },
            onTapVoiceMemo: openBuilderInVoiceMemoMode
        )
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.bottom, DesignConstants.Spacing.step4x)
        .matchedTransitionSource(id: Constant.builderTransitionId, in: namespace)
    }

    private func openBuilder() {
        conversationsViewModel.onStartAssistant()
    }

    /// Open the builder and immediately start voice-memo recording. The
    /// builder's voice-memo recorder is created lazily inside its init
    /// path, so we schedule the start call on the next runloop tick to
    /// give the VM a moment to wire up before we call `startRecording`.
    private func openBuilderInVoiceMemoMode() {
        conversationsViewModel.onStartAssistant()
        guard let builderViewModel = conversationsViewModel.assistantBuilderViewModel else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            builderViewModel.startVoiceMemoRecording(restoreComposerFocusAfter: true)
        }
    }

    /// Camera capture (still image): open the builder and load the image
    /// into the inner conversation VM's attachment list. The fullScreenCover
    /// is dismissed by flipping `isCameraPresented` before opening the
    /// builder so the sheet sits on top of the (now-dismissing) camera
    /// cover with no visible flash.
    private func handleCameraImageCaptured(_ image: UIImage) {
        isCameraPresented = false
        conversationsViewModel.onStartAssistant()
        guard let builderViewModel = conversationsViewModel.assistantBuilderViewModel else { return }
        builderViewModel.addPhotoAttachment(image)
    }

    private func handleCameraVideoCaptured(_ url: URL) {
        isCameraPresented = false
        conversationsViewModel.onStartAssistant()
        guard let builderViewModel = conversationsViewModel.assistantBuilderViewModel else { return }
        builderViewModel.addVideoAttachment(url: url)
    }

    /// Photo / video library selection: load each picked item asynchronously
    /// (videos transferred as `VideoFile`, stills as `Data` -> `UIImage`)
    /// and add them to the freshly-created builder VM. The picker is
    /// dismissed and `selectedPhotos` is cleared synchronously so a
    /// subsequent tap on the photo icon opens the picker fresh.
    private func handleSelectedPhotosChanged(to newValue: [PhotosPickerItem]) {
        guard !newValue.isEmpty else { return }
        let items = newValue
        selectedPhotos = []
        isPhotoPickerPresented = false
        conversationsViewModel.onStartAssistant()
        guard let builderViewModel = conversationsViewModel.assistantBuilderViewModel else { return }
        Task {
            for item in items {
                if let videoFile = try? await item.loadTransferable(type: VideoFile.self) {
                    await MainActor.run { builderViewModel.addVideoAttachment(url: videoFile.url) }
                } else if let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) {
                    await MainActor.run { builderViewModel.addPhotoAttachment(image) }
                }
            }
        }
    }

    private enum Constant {
        static let builderTransitionId: String = "assistant-builder-transition-source"
        static let appSettingsTransitionId: String = "app-settings-transition-source"
        static let composerTransitionId: String = "composer-transition-source"
    }
}
