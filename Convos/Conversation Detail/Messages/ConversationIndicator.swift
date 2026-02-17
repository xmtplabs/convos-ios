import ConvosCore
import SwiftUI

struct ConversationIndicator<InfoView: View>: View {
    let conversation: Conversation
    let placeholderName: String
    let untitledConversationPlaceholder: String
    let subtitle: String
    @Binding var conversationName: String
    @Binding var conversationImage: UIImage?
    @Binding var presentingConversationSettings: Bool
    @Binding var activeToast: IndicatorToastStyle?
    @Binding var autoRevealPhotos: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator?
    let showsExplodeNowButton: Bool
    let explodeState: ExplodeState
    let onConversationInfoTapped: () -> Void
    let onConversationInfoLongPressed: () -> Void
    let onConversationNameEndedEditing: () -> Void
    let onConversationSettings: () -> Void
    let onExplodeNow: () -> Void
    @ViewBuilder let infoView: () -> InfoView

    @State private var isExpanded: Bool = false
    @State private var showingToast: Bool = false
    @State private var isImagePickerPresented: Bool = false
    @Namespace private var namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer {
            ZStack {
                if showingToast, let toast = activeToast {
                    IndicatorToast(
                        style: toast,
                        isAutoReveal: $autoRevealPhotos,
                        onDismiss: dismissToast
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .opacity
                    ))
                } else if !isExpanded {
                    ConversationToolbarButton(
                        conversation: conversation,
                        conversationImage: $conversationImage,
                        conversationName: conversationName,
                        placeholderName: untitledConversationPlaceholder,
                        subtitle: subtitle,
                        action: onConversationInfoTapped,
                        longPressAction: onConversationInfoLongPressed
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("convoInfo", in: namespace)
                    .glassEffectTransition(.matchedGeometry)
                } else {
                    VStack(spacing: DesignConstants.Spacing.step4x) {
                        QuickEditView(
                            placeholderText: conversationName.isEmpty ? placeholderName : conversationName,
                            text: $conversationName,
                            image: $conversationImage,
                            isImagePickerPresented: $isImagePickerPresented,
                            focusState: $focusState,
                            focused: .conversationName,
                            settingsSymbolName: "gear",
                            showsSettingsButton: true,
                            onSubmit: onConversationNameEndedEditing,
                            onSettings: onConversationSettings
                        )

                        if showsExplodeNowButton {
                            ExplodeButton(state: explodeState) {
                                onExplodeNow()
                            }
                        }
                    }
                    .frame(maxWidth: 320.0)
                    .padding(DesignConstants.Spacing.step6x)
                    .clipShape(.rect(cornerRadius: 40.0))
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 40.0))
                    .glassEffectID("convoEditor", in: namespace)
                    .glassEffectTransition(.matchedGeometry)
                }
            }
        }
        .matchedTransitionSource(
            id: "convo-info-transition-source",
            in: namespace
        )
        .sheet(isPresented: $presentingConversationSettings) {
            infoView()
                .navigationTransition(
                    .zoom(
                        sourceID: "convo-info-transition-source",
                        in: namespace
                    )
                )
        }
        .onChange(of: activeToast) { _, newValue in
            if newValue != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded = false
                    showingToast = true
                }
            }
        }
        .onChange(of: focusCoordinator?.currentFocus) { _, newValue in
            guard !isImagePickerPresented, !showingToast else { return }

            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                isExpanded = newValue == .conversationName ? true : false
            }
        }
        .onChange(of: isImagePickerPresented) { _, newValue in
            guard newValue == false else { return }
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.01)) {
                isExpanded = (focusCoordinator?.currentFocus == .conversationName)
            }
        }
    }

    private func dismissToast() {
        withAnimation(.easeOut(duration: 0.2)) {
            showingToast = false
            activeToast = nil
        }
    }
}

#Preview {
    @Previewable @State var conversationName: String = ""
    @Previewable @State var conversationImage: UIImage?
    @Previewable @State var focusCoordinator: FocusCoordinator? = FocusCoordinator(horizontalSizeClass: nil)
    @Previewable @State var presentingConversationSettings: Bool = false
    @Previewable @State var activeToast: IndicatorToastStyle?
    @Previewable @State var autoRevealPhotos: Bool = false
    @Previewable @FocusState var focusState: MessagesViewInputFocus?

    let conversation: Conversation = .mock()
    let placeholderName: String = conversation.name ?? "Convo name"

    VStack {
        ConversationIndicator(
            conversation: conversation,
            placeholderName: placeholderName,
            untitledConversationPlaceholder: "Untitled",
            subtitle: "Customize",
            conversationName: $conversationName,
            conversationImage: $conversationImage,
            presentingConversationSettings: $presentingConversationSettings,
            activeToast: $activeToast,
            autoRevealPhotos: $autoRevealPhotos,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            showsExplodeNowButton: true,
            explodeState: .ready,
            onConversationInfoTapped: {
                focusCoordinator?.moveFocus(to: .conversationName)
            },
            onConversationInfoLongPressed: {
                focusCoordinator?.moveFocus(to: .conversationName)
            },
            onConversationNameEndedEditing: {
                focusCoordinator?.moveFocus(to: nil)
            },
            onConversationSettings: {},
            onExplodeNow: {},
            infoView: {
                EmptyView()
            }
        )

        Button("Show Toast") {
            activeToast = .revealSettings(isAutoReveal: autoRevealPhotos)
        }
    }
}
