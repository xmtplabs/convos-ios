import SwiftUI

struct AssistantPresentInfoView: View {
    let onAboutAssistants: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text("An assistant is in this convo. It learns by listening — in this convo only. It can browse, call, text, email, pay and more.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)

            let action = { onAboutAssistants() }
            Button(action: action) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Circle()
                        .fill(.colorLava)
                        .frame(width: 20, height: 20)
                    Text("About assistants")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextPrimary)
                }
                .padding(DesignConstants.Spacing.step2x)
                .padding(.trailing, DesignConstants.Spacing.stepX)
                .background(.colorLava.opacity(0.1), in: .capsule)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignConstants.Spacing.stepX)
        .padding(.bottom, DesignConstants.Spacing.step4x)
    }
}

#Preview {
    AssistantPresentInfoView(onAboutAssistants: {})
}
