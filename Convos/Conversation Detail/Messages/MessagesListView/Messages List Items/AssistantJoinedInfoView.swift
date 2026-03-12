import SwiftUI

struct AssistantJoinedInfoView: View {
    let onAboutAssistants: () -> Void

    var body: some View {
        let action = { onAboutAssistants() }
        Button(action: action) {
            Text("See what it can do")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .background(.colorLava, in: .capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, DesignConstants.Spacing.step4x)
    }
}

#Preview {
    AssistantJoinedInfoView(onAboutAssistants: {})
}
