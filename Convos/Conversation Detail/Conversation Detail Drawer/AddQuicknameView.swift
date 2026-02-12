import ConvosCore
import SwiftUI

struct AddQuicknameView: View {
    @Binding var profile: Profile
    @Binding var profileImage: UIImage?
    let onUseProfile: (Profile, UIImage?) -> Void

    var body: some View {
        Button {
            onUseProfile(profile, profileImage)
        } label: {
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
        }
        .accessibilityLabel("Chat as \(profile.displayName)")
        .accessibilityIdentifier("add-quickname-button")
        .hoverEffect(.lift)
        .padding(.vertical, DesignConstants.Spacing.step4x)
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
        )
        .id(resetId)

        Button("Replay") {
            resetId = UUID()
        }
        .buttonStyle(.borderedProminent)
    }
    .padding()
}
