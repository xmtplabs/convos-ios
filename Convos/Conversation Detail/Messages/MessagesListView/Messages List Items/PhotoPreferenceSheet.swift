import SwiftUI

struct PhotoPreferenceSheet: View {
    let onAutoReveal: () -> Void
    let onAskEveryTime: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Photo revealed")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("Would you like to automatically reveal photos from this person in the future?")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                let autoRevealAction = { onAutoReveal() }
                Button(action: autoRevealAction) {
                    Text("Always reveal")
                }
                .convosButtonStyle(.rounded(fullWidth: true))

                let askEveryTimeAction = { onAskEveryTime() }
                Button(action: askEveryTimeAction) {
                    Text("Ask every time")
                }
                .convosButtonStyle(.outline(fullWidth: true))
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step6x)
    }
}

#Preview {
    @Previewable @State var isPresented = true

    VStack {
        Button {
            isPresented.toggle()
        } label: {
            Text("Show Sheet")
        }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        PhotoPreferenceSheet(
            onAutoReveal: { print("Auto reveal selected") },
            onAskEveryTime: { print("Ask every time selected") }
        )
        .background(.colorBackgroundRaised)
    }
}
