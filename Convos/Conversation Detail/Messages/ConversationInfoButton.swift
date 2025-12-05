import ConvosCore
import SwiftUI

struct ConversationInfoButton<InfoView: View>: View {
    let conversation: Conversation
    let placeholderName: String
    let untitledConversationPlaceholder: String
    let subtitle: String
    @Binding var conversationName: String
    @Binding var conversationImage: UIImage?
    @Binding var presentingConversationSettings: Bool
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator?
    let showsExplodeNowButton: Bool
    let onConversationInfoTapped: () -> Void
    let onConversationNameEndedEditing: () -> Void
    let onConversationSettings: () -> Void
    let onExplodeNow: () -> Void
    @ViewBuilder let infoView: () -> InfoView

    @State private var isExpanded: Bool = false
    @State private var showingExplodeConfirmation: Bool = false
    @State private var isImagePickerPresented: Bool = false
    @Namespace private var namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer {
            ZStack {
                if !isExpanded {
                    ConversationToolbarButton(
                        conversation: conversation,
                        conversationImage: $conversationImage,
                        conversationName: conversationName,
                        placeholderName: untitledConversationPlaceholder,
                        subtitle: subtitle,
                        action: onConversationInfoTapped
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("convoInfo", in: namespace)
                    .glassEffectTransition(.matchedGeometry)
                }

                if isExpanded {
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
                            Button {
                                showingExplodeConfirmation = true
                            } label: {
                                Text("Explode now")
                            }
                            .buttonStyle(RoundedDestructiveButtonStyle(fullWidth: true))
                            .confirmationDialog(
                                "",
                                isPresented: $showingExplodeConfirmation
                            ) {
                                Button("Explode", role: .destructive) {
                                    onExplodeNow()
                                }

                                Button("Cancel") {
                                    showingExplodeConfirmation = false
                                }
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
        .onChange(of: focusCoordinator?.currentFocus) { _, newValue in
            guard !isImagePickerPresented else { return }

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
}

#Preview {
    @Previewable @State var conversationName: String = ""
    @Previewable @State var conversationImage: UIImage?
    @Previewable @State var focusCoordinator: FocusCoordinator? = FocusCoordinator(horizontalSizeClass: nil)
    @Previewable @State var presentingConversationSettings: Bool = false
    @Previewable @FocusState var focusState: MessagesViewInputFocus?

    let conversation: Conversation = .mock()
    let placeholderName: String = conversation.name ?? "Name"

    ConversationInfoButton(
        conversation: conversation,
        placeholderName: placeholderName,
        untitledConversationPlaceholder: "Untitled",
        subtitle: "Customize",
        conversationName: $conversationName,
        conversationImage: $conversationImage,
        presentingConversationSettings: $presentingConversationSettings,
        focusState: $focusState,
        focusCoordinator: focusCoordinator,
        showsExplodeNowButton: true,
        onConversationInfoTapped: {
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
}
