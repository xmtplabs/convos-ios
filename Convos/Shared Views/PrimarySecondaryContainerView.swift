import ConvosCore
import SwiftUI

struct PrimarySecondaryContainerView<PrimaryContent: View,
                                     SecondaryContent: View>: View, Animatable {
    var progress: CGFloat = 0.0
    let primaryProperties: ViewProperties
    let secondaryProperties: ViewProperties
    @ViewBuilder var primaryContent: PrimaryContent
    @ViewBuilder var secondaryContent: SecondaryContent

    @State private var contentSize: CGSize = .zero
    @State private var secondaryContentSize: CGSize = .zero
    @State private var primaryContentSize: CGSize = .zero

    struct ViewProperties {
        let cornerRadius: CGFloat?
        let padding: CGFloat
        let fixedSizeHorizontal: Bool
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var secondaryContentOpacity: CGFloat {
        max(progress - 0.35, 0) / 0.65
    }

    var primaryContentOpacity: CGFloat {
        1.0 - min(progress / 0.35, 1)
    }

    var primaryCornerRadius: CGFloat {
        guard let cornerRadius = primaryProperties.cornerRadius else {
            return primaryContentSize.height / 2.0
        }
        return cornerRadius
    }

    var secondaryCornerRadius: CGFloat {
        guard let cornerRadius = secondaryProperties.cornerRadius else {
            return secondaryContentSize.height / 2.0
        }
        return cornerRadius
    }

    var cornerRadius: CGFloat {
        interpolate(primaryCornerRadius, secondaryCornerRadius)
    }

    var primaryPadding: CGFloat {
        primaryProperties.padding
    }

    var secondaryPadding: CGFloat {
        secondaryProperties.padding
    }

    var padding: CGFloat {
        interpolate(primaryPadding, secondaryPadding)
    }

    var blurAmount: CGFloat {
        8.0
    }

    var blurProgress: CGFloat {
        /// 0 -> 0.5 -> 0
        progress > 0.5 ? (1 - progress) / 0.5 : progress / 0.5
    }

    var contentScale: CGFloat {
        let minAspectScale = min(secondaryContentSize.width / primaryContentSize.width, secondaryContentSize.height / primaryContentSize.height)

        return minAspectScale + (1 - minAspectScale) * progress
    }

    private func interpolate(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }

    var body: some View {
        ZStack {
            let widthDiff = (secondaryContentSize.width - primaryContentSize.width)
            let heightDiff = (secondaryContentSize.height - primaryContentSize.height)

            let rWidth = widthDiff * progress
            let rHeight = heightDiff * progress

            secondaryContent
                .padding(padding)
                .compositingGroup()
                .scaleEffect(contentScale)
                .blur(radius: blurAmount * blurProgress)
                .opacity(secondaryContentOpacity)
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { newValue in
                    secondaryContentSize = newValue
                }
                .fixedSize(horizontal: secondaryProperties.fixedSizeHorizontal, vertical: false)
                .frame(
                    width: primaryContentSize.width + rWidth,
                    height: primaryContentSize.height + rHeight
                )

            primaryContent
                .padding(padding)
                .compositingGroup()
                .blur(radius: blurAmount * blurProgress)
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { newValue in
                    primaryContentSize = newValue
                }
                .opacity(primaryContentOpacity)
                .fixedSize(horizontal: primaryProperties.fixedSizeHorizontal, vertical: true)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: cornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        .scaleEffect(
            x: 1 + (blurProgress * 0.15),
            y: 1 - (blurProgress * 0.05)
        )
    }
}

#Preview {
    @Previewable @State var image: UIImage?
    @Previewable @State var conversationImage: UIImage?
    @Previewable @State var text: String = ""
    @Previewable @State var topProgress: CGFloat = 0.0
    @Previewable @State var bottomProgress: CGFloat = 0.0
    @Previewable @State var isImagePickerPresented: Bool = false
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    let conversation: Conversation = .mock()

    ZStack {
        VStack {
            Spacer()
            VStack {
                Slider(value: $topProgress)
                Button {
                    withAnimation(.bouncy(duration: 0.4, extraBounce: 0.15)) {
                        topProgress = topProgress == 1.0 ? 0.0 : 1.0
                    }
                } label: {
                    Text("Toggle Top")
                }
                Spacer().frame(height: 80.0)
                Slider(value: $bottomProgress)
                Button {
                    withAnimation(.bouncy(duration: 0.4, extraBounce: 0.15)) {
                        bottomProgress = bottomProgress == 1.0 ? 0.0 : 1.0
                    }
                } label: {
                    Text("Toggle Bottom")
                }
            }
            .padding(.horizontal, 24.0)

            Spacer()
        }

        VStack {
            PrimarySecondaryContainerView(
                progress: topProgress,
                primaryProperties: .init(
                    cornerRadius: nil,
                    padding: DesignConstants.Spacing.step2x,
                    fixedSizeHorizontal: false
                ),
                secondaryProperties: .init(
                    cornerRadius: 40.0,
                    padding: DesignConstants.Spacing.step6x,
                    fixedSizeHorizontal: true
                )
            ) {
                ConversationToolbarButton(
                    conversation: conversation,
                    conversationImage: $conversationImage,
                    conversationName: conversation.name ?? "",
                    placeholderName: "Draft"
                ) {
                }
            } secondaryContent: {
                QuickEditView(
                    placeholderText: "The Convo",
                    text: $text,
                    image: $image,
                    isImagePickerPresented: $isImagePickerPresented,
                    focusState: $focusState,
                    focused: .conversationName,
                    onSubmit: {},
                    onSettings: {}
                )
            }

            Spacer()

            PrimarySecondaryContainerView(
                progress: bottomProgress,
                primaryProperties: .init(
                    cornerRadius: nil,
                    padding: DesignConstants.Spacing.step2x,
                    fixedSizeHorizontal: false
                ),
                secondaryProperties: .init(
                    cornerRadius: 40.0,
                    padding: DesignConstants.Spacing.step6x,
                    fixedSizeHorizontal: false
                )
            ) {
                HStack {
                    Button {
                    } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.gray)
                            .frame(width: 40.0, height: 40.0)
                    }
                    .frame(width: 40.0, height: 40.0)

                    TextField("Chat as Somebody...", text: $text)
                        .frame(maxWidth: .infinity)

                    Button {
                    } label: {
                        Image(systemName: "arrow.up")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.colorTextPrimaryInverted)
                            .padding(.horizontal, 12.0)
                    }
                    .frame(width: 40.0, height: 40.0)
                    .background(Circle().fill(.black.opacity(0.2)))
                }
            } secondaryContent: {
                QuickEditView(
                    placeholderText: "Somebody...",
                    text: $text,
                    image: $image,
                    isImagePickerPresented: $isImagePickerPresented,
                    focusState: $focusState,
                    focused: .displayName,
                    onSubmit: {},
                    onSettings: {}
                )
                .padding(.horizontal, 16.0)
            }
        }
        .padding(.horizontal, 16.0)
    }
}
