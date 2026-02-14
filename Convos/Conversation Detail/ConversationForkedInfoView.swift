import SwiftUI

struct ConversationForkedInfoView: View {
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Error 01")
                    .textCase(.uppercase)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)

                Text("Network issue")
                    .font(.system(.largeTitle))
                    .fontWeight(.bold)
                    .padding(.bottom, DesignConstants.Spacing.step4x)

                Text("Convos has detected a problem with the messaging network.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text("Everything is secure, but this convo can’t continue correctly. Please delete it and pop up a new one.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    onDelete()
                } label: {
                    Text("Delete convo")
                }
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorBackgroundInverted))

                Button {
                    // swiftlint:disable:next force_unwrapping
                    openURL(URL(string: "https://learn.convos.org/error-01")!)
                } label: {
                    Text("Learn more")
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-forked-info")
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
}

#Preview {
    @Previewable @State var presenting: Bool = false
    VStack {
        Button {
            presenting.toggle()
        } label: {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        ConversationForkedInfoView {
        }
    }
}
