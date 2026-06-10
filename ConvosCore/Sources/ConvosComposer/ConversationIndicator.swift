#if canImport(UIKit)
import ConvosCore
import SwiftUI

public struct ConversationIndicator<InfoView: View, QuickEdit: View>: View {
    let conversation: Conversation
    let placeholderName: String
    let untitledConversationPlaceholder: String
    let subtitle: String
    let scheduledExplosionDate: Date?
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
    /// App-provided quick-edit editor shown when the indicator expands for
    /// conversation-name editing. Receives the computed placeholder text and
    /// a binding to the indicator's image-picker presentation state.
    @ViewBuilder let quickEditView: (String, Binding<Bool>) -> QuickEdit

    @State private var isExpanded: Bool = false
    @State private var showingToast: Bool = false
    @State private var isImagePickerPresented: Bool = false
    @Namespace private var namespace: Namespace.ID

    public init(
        conversation: Conversation,
        placeholderName: String,
        untitledConversationPlaceholder: String,
        subtitle: String,
        scheduledExplosionDate: Date? = nil,
        conversationName: Binding<String>,
        conversationImage: Binding<UIImage?>,
        presentingConversationSettings: Binding<Bool>,
        activeToast: Binding<IndicatorToastStyle?>,
        autoRevealPhotos: Binding<Bool>,
        focusState: FocusState<MessagesViewInputFocus?>.Binding,
        focusCoordinator: FocusCoordinator?,
        showsExplodeNowButton: Bool,
        explodeState: ExplodeState,
        onConversationInfoTapped: @escaping () -> Void,
        onConversationInfoLongPressed: @escaping () -> Void,
        onConversationNameEndedEditing: @escaping () -> Void,
        onConversationSettings: @escaping () -> Void,
        onExplodeNow: @escaping () -> Void,
        @ViewBuilder infoView: @escaping () -> InfoView,
        @ViewBuilder quickEditView: @escaping (String, Binding<Bool>) -> QuickEdit
    ) {
        self.conversation = conversation
        self.placeholderName = placeholderName
        self.untitledConversationPlaceholder = untitledConversationPlaceholder
        self.subtitle = subtitle
        self.scheduledExplosionDate = scheduledExplosionDate
        _conversationName = conversationName
        _conversationImage = conversationImage
        _presentingConversationSettings = presentingConversationSettings
        _activeToast = activeToast
        _autoRevealPhotos = autoRevealPhotos
        _focusState = focusState
        self.focusCoordinator = focusCoordinator
        self.showsExplodeNowButton = showsExplodeNowButton
        self.explodeState = explodeState
        self.onConversationInfoTapped = onConversationInfoTapped
        self.onConversationInfoLongPressed = onConversationInfoLongPressed
        self.onConversationNameEndedEditing = onConversationNameEndedEditing
        self.onConversationSettings = onConversationSettings
        self.onExplodeNow = onExplodeNow
        self.infoView = infoView
        self.quickEditView = quickEditView
    }

    public var body: some View {
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
                        scheduledExplosionDate: scheduledExplosionDate,
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
                        quickEditView(
                            conversationName.isEmpty ? placeholderName : conversationName,
                            $isImagePickerPresented
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
#endif
