import SwiftUI

// swiftlint:disable force_unwrapping

struct ConversationsListEmptyCTA: View {
    let onStartConvo: () -> Void
    let onJoinConvo: () -> Void

    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(spacing: 0.0) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                Text("Pop-up private convos")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.colorTextPrimary)
                Text("Chat instantly, with anybody.\nNo accounts. New you every time.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                HStack {
                    Button {
                        onStartConvo()
                    } label: {
                        Text("Start a convo")
                            .font(.body)
                    }
                    .convosButtonStyle(.rounded(fullWidth: false))
                    .hoverEffect(.lift)
                    Button {
                        onJoinConvo()
                    } label: {
                        Text("or join one")
                    }
                    .convosButtonStyle(.text)
                    .hoverEffect(.lift)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.colorFillMinimal)
            .cornerRadius(32.0)

            HStack(spacing: DesignConstants.Spacing.step4x) {
                Button {
                    openURL(URL(string: "https://xmtp.org")!, prefersInApp: true)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 0.0) {
                        Text("Secured by ")
                        Image("xmtpIcon")
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 10.0, height: 10.0)
                            .padding(.leading, 2.0)
                            .padding(.trailing, 1.0)
                            .offset(y: 0.5)
                        Text("XMTP")
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.colorTextTertiary)
                            .padding(.leading, DesignConstants.Spacing.stepX)
                    }
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                }

                Button {
                    openURL(URL(string: "https://convos.org/terms-and-privacy")!, prefersInApp: true)
                } label: {
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Text("Terms & Privacy Policy")
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.colorTextTertiary)
                    }
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                }
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(DesignConstants.Spacing.step6x)
        .background(.colorBackgroundSurfaceless)
    }
}

// swiftlint:enable force_unwrapping

#Preview {
    ConversationsListEmptyCTA {
    } onJoinConvo: {
    }
}
