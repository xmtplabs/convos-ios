import SwiftUI

struct PendingDMView: View {
    @State private var showingDescription: Bool = false

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            HStack {
                Image(systemName: "tray.fill")
                    .font(.footnote)
                    .foregroundStyle(.colorLava)
                Text("Pending DM")
                    .foregroundStyle(.colorTextPrimary)
            }
            .font(.body)

            if showingDescription {
                Text("Convo will start when other member\u{2019}s device approves")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .transition(.blurReplace)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: showingDescription)
        .padding(DesignConstants.Spacing.step6x)
        .frame(maxWidth: .infinity)
        .background(.colorFillMinimal)
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pending-dm-view")
        .accessibilityLabel("Pending DM. Convo will start when other member\u{2019}s device approves.")
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation {
                    self.showingDescription = true
                }
            }
        }
    }
}

#Preview {
    VStack {
        PendingDMView()
    }
}
