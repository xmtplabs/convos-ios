import SwiftUI

struct LockedConvoInfoView: View {
    let isCurrentUserSuperAdmin: Bool
    let onUnlock: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Locked")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("Nobody new can join this convo.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)

            Text("New convo codes can't be created, and any outstanding codes no longer work.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                if isCurrentUserSuperAdmin {
                    Button {
                        onUnlock()
                    } label: {
                        Text("Unlock")
                    }
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorBackgroundInverted))

                    Button {
                        onDismiss()
                    } label: {
                        Text("Keep locked")
                    }
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
                } else {
                    Button {
                        onDismiss()
                    } label: {
                        Text("Got it")
                    }
                    .convosButtonStyle(.rounded(fullWidth: true))
                }
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}

#Preview("Super Admin") {
    @Previewable @State var presenting: Bool = true
    VStack {
        Button {
            presenting.toggle()
        } label: {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        LockedConvoInfoView(
            isCurrentUserSuperAdmin: true,
            onUnlock: {},
            onDismiss: {}
        )
        .background(.colorBackgroundRaised)
    }
}

#Preview("Non-Admin") {
    @Previewable @State var presenting: Bool = true
    VStack {
        Button {
            presenting.toggle()
        } label: {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        LockedConvoInfoView(
            isCurrentUserSuperAdmin: false,
            onUnlock: {},
            onDismiss: {}
        )
        .background(.colorBackgroundRaised)
    }
}
