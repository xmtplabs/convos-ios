import ConvosCore
import SwiftUI

struct AddQuicknameView: View {
    @Binding var profile: Profile
    @Binding var profileImage: UIImage?
    let onUseProfile: (Profile, UIImage?) -> Void
    var onDismiss: (() -> Void)?

    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing: Bool = false
    @GestureState private var isDragging: Bool = false

    private var dragDistance: CGFloat {
        sqrt(dragOffset.width * dragOffset.width + dragOffset.height * dragOffset.height)
    }

    private var dismissProgress: CGFloat {
        min(dragDistance / Constant.dismissThreshold, 1.0)
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            ProfileAvatarView(
                profile: profile,
                profileImage: profileImage,
                useSystemPlaceholder: false
            )
            .frame(width: 24.0, height: 24.0)

            Text("Tap to chat as \(profile.displayName)")
                .font(.callout)
                .foregroundStyle(.colorTextPrimaryInverted)
        }
        .padding(.vertical, DesignConstants.Spacing.step3HalfX)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .background(
            DrainingCapsule(
                fillColor: .colorBackgroundInverted,
                backgroundColor: .colorFillSecondary,
                duration: ConversationOnboardingState.addQuicknameViewDuration
            )
        )
        .accessibilityLabel("Chat as \(profile.displayName)")
        .accessibilityIdentifier("add-quickname-button")
        .hoverEffect(.lift)
        .offset(dragOffset)
        .scaleEffect(isDismissing ? Constant.poofScale : 1.0 - dismissProgress * 0.08)
        .blur(radius: isDismissing ? Constant.poofBlurRadius : dismissProgress * Constant.maxBlurRadius)
        .opacity(isDismissing ? 0.0 : 1.0)
        .onTapGesture {
            guard !isDismissing else { return }
            onUseProfile(profile, profileImage)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .updating($isDragging) { _, state, _ in
                    state = true
                }
                .onChanged { value in
                    dragOffset = elasticOffset(for: value.translation)
                }
                .onEnded { value in
                    let distance = sqrt(
                        value.translation.width * value.translation.width +
                        value.translation.height * value.translation.height
                    )
                    let predictedDistance = sqrt(
                        value.predictedEndTranslation.width * value.predictedEndTranslation.width +
                        value.predictedEndTranslation.height * value.predictedEndTranslation.height
                    )

                    let shouldDismiss = distance > Constant.dismissThreshold ||
                        predictedDistance > Constant.dismissThreshold * 2
                    if onDismiss != nil, shouldDismiss {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isDismissing = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onDismiss?()
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.8), value: dragOffset)
        .padding(.vertical, DesignConstants.Spacing.step4x)
    }

    private func elasticOffset(for translation: CGSize) -> CGSize {
        CGSize(
            width: rubberClamp(translation.width),
            height: rubberClamp(translation.height)
        )
    }

    private func rubberClamp(_ value: CGFloat) -> CGFloat {
        let sign = value >= 0 ? 1.0 : -1.0
        let absValue = abs(value)
        let limit = Constant.maxDragDistance
        let clamped = limit * (1 - pow(2, -absValue / (limit / 2)))
        return sign * clamped
    }

    private enum Constant {
        static let dismissThreshold: CGFloat = 120.0
        static let maxDragDistance: CGFloat = 200.0
        static let maxBlurRadius: CGFloat = 6.0
        static let poofScale: CGFloat = 1.3
        static let poofBlurRadius: CGFloat = 12.0
    }
}

#Preview {
    @Previewable @State var profile: Profile = .mock()
    @Previewable @State var profileImage: UIImage?
    @Previewable @State var resetId = UUID()

    VStack(spacing: 20) {
        AddQuicknameView(
            profile: $profile,
            profileImage: $profileImage,
            onUseProfile: { _, _ in },
            onDismiss: { print("Dismissed") }
        )
        .id(resetId)

        Button("Replay") {
            resetId = UUID()
        }
        .buttonStyle(.borderedProminent)
    }
    .padding()
}
