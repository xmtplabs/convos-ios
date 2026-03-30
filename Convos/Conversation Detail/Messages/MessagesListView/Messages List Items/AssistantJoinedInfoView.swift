import SwiftUI

struct AssistantJoinedInfoView: View {
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        let action = {
            if let url = URL(string: Constant.assistantsURLString) {
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

    private enum Constant {
        static let assistantsURLString: String = "https://www.convos.org/assistants"
    }
}

#Preview {
    AssistantJoinedInfoView()
}
