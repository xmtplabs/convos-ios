import SwiftUI

struct WhatIsQuicknameView: View {
    let onContinue: () -> Void

    @State private var quicknameSettings: QuicknameSettingsViewModel = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Infinite identities")
                .font(.caption)
                .foregroundColor(.colorTextSecondary)
            Text("You're a new you in every convo")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text("Choose to add a name or pic, or not. You always start anonymous.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)

            Text("You have a Quickname for easy re-use")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProfileAvatarView(
                    profile: quicknameSettings.profile,
                    profileImage: quicknameSettings.profileImage,
                    useSystemPlaceholder: false
                )
                .frame(width: 32.0, height: 32.0)
                .padding(.leading, 10.0)
                .padding(.vertical, 10.0)

                Text(
                    quicknameSettings.editingDisplayName.isEmpty ? "Somebody" : quicknameSettings.editingDisplayName
                )
                .foregroundStyle(.colorTextPrimary)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .stroke(.colorBorderSubtle, lineWidth: 1.0)
            )

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    onContinue()
                } label: {
                    Text("Continue")
                }
                .convosButtonStyle(.rounded(fullWidth: true))
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}

#Preview {
    @Previewable @State var presentingLearnMore: Bool = false
    VStack {
        Button {
            presentingLearnMore.toggle()
        } label: {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presentingLearnMore) {
        WhatIsQuicknameView {}
            .background(.colorBackgroundRaised)
    }
}
