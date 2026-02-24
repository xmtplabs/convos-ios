import SwiftUI

struct InviteAcceptedView: View {
    @State private var showingDescription: Bool = false

    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        Button {
            openURL(Constant.learnMoreURL)
        } label: {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                HStack {
                    Image(systemName: "qrcode")
                        .font(.footnote)
                        .foregroundStyle(.colorLava)
                    Text("Verifying")
                        .foregroundStyle(.colorTextPrimary)
                }
                .font(.body)

                if showingDescription {
                    Text("See and send messages after your access is verified")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .transition(.blurReplace)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: showingDescription)
            .padding(DesignConstants.Spacing.step6x)
            .frame(maxWidth: .infinity)
            .background(.colorFillMinimal)
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("invite-accepted-view")
        .accessibilityLabel("Verifying. See and send messages after your access is verified.")
        .onAppear {
            DispatchQueue.main
                .asyncAfter(deadline: .now() + ConversationOnboardingState.waitingForInviteAcceptanceDelay) {
                withAnimation {
                    self.showingDescription = true
                }
            }
        }
    }

    private enum Constant {
        // swiftlint:disable:next force_unwrapping
        static let learnMoreURL: URL = URL(string: "https://learn.convos.org/verifying")!
    }
}

#Preview {
    VStack {
        InviteAcceptedView()
    }
}
