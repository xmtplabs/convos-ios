import SwiftUI

struct AssistantProcessingPowerInfoView: View {
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    private let horizontalPadding: CGFloat = DesignConstants.Spacing.step10x

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Instant Assistants")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)

            Text("Assistants require processing power")
                .font(.convosTitle)
                .tracking(Font.convosTitleTracking)

            Text("This assistant has maxed out its power allocation and is now paused indefinitely.")
                .font(.body)
                .foregroundStyle(.colorLava)

            Text("We\u{2019}re working to expand free capacity and enable you to fund your own processing power.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                let learnURL = URL(string: "https://learn.convos.org/assistants-processing-power")
                let learnAction = { if let learnURL { openURL(learnURL) } }
                Button(action: learnAction) {
                    Text("Learn about power")
                }
                .convosButtonStyle(.rounded(fullWidth: true))

                let dismissAction = { dismiss() }
                Button(action: dismissAction) {
                    Text("Continue")
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : DesignConstants.Spacing.step6x)
        .sheetDragIndicator(.hidden)
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { AssistantProcessingPowerInfoView().padding(.top, 20) }
}
