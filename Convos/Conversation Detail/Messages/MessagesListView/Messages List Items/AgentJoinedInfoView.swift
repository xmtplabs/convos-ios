import SwiftUI

struct AgentJoinedInfoView: View {
    @State private var safariURL: URL?

    var body: some View {
        let action = { safariURL = URL(string: Constant.agentsURLString) }
        Button(action: action) {
            Text("See its skills")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step3HalfX)
                .background(Capsule().fill(.colorLava))
        }
        .padding(.bottom, DesignConstants.Spacing.step4x)
        .safariSheet(url: $safariURL)
    }

    private enum Constant {
        static let agentsURLString: String = "https://www.convos.org/assistants"
    }
}

#Preview {
    AgentJoinedInfoView()
}
