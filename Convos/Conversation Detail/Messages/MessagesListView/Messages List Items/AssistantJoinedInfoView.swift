import SwiftUI

struct AssistantJoinedInfoView: View {
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        let action = {
            if let url = URL(string: "https://www.convos.org/skills") {
                openURL(url, prefersInApp: true)
            }
        }
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
    AssistantJoinedInfoView()
}
