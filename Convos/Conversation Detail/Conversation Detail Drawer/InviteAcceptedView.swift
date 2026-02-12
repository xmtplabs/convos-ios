import SwiftUI

struct InviteAcceptedView: View {
    @State private var showingDescription: Bool = false

    var body: some View {
        Group {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.colorGreen)
                    Text("Invite accepted")
                        .foregroundStyle(.colorTextPrimary)
                }
                .font(.body)

                if showingDescription {
                    Text("See and send messages after someone approves you.")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .transition(.blurReplace)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: showingDescription)
            .padding(DesignConstants.Spacing.step6x)
        }
        .frame(maxWidth: .infinity)
        .background(.colorFillMinimal)
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Invite accepted. See and send messages after someone approves you.")
        .onAppear {
            DispatchQueue.main
                .asyncAfter(deadline: .now() + ConversationOnboardingState.waitingForInviteAcceptanceDelay) {
                withAnimation {
                    self.showingDescription = true
                }
            }
        }
    }
}

#Preview {
    VStack {
        InviteAcceptedView()
    }
}
