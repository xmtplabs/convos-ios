import SwiftUI

struct AssistantJoinedInfoView: View {
    @State private var safariURL: URL?

    var body: some View {
        let action = { safariURL = URL(string: Constant.assistantsURLString) }
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
        static let assistantsURLString: String = "https://www.convos.org/assistants"
    }
}

#Preview {
    AssistantJoinedInfoView()
}
