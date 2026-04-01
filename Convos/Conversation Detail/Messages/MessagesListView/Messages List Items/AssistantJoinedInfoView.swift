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
            Text("See its skills")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step3HalfX)
                .background(Capsule().fill(.colorLava))
        }
        .padding(.bottom, DesignConstants.Spacing.step4x)
    }

    private enum Constant {
        static let assistantsURLString: String = "https://www.convos.org/assistants"
    }
}

#Preview {
    AssistantJoinedInfoView()
}
