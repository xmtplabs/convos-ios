import SwiftUI

struct LockedConvoInfoView: View {
    let isCurrentUserSuperAdmin: Bool
    let isLocked: Bool
    let onLock: () -> Void
    let onDismiss: () -> Void

    private var title: String {
        if isCurrentUserSuperAdmin && !isLocked {
            return "Lock?"
        }
        return "Locked"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(title)
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            if isCurrentUserSuperAdmin {
                Text("Nobody new can join this convo.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text(isLocked
                    ? "New convo codes can't be created, and any outstanding codes no longer work."
                    : "New convo codes can't be created, and any outstanding codes will no longer work.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            } else {
                Text("Nobody new can join this convo.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text("New convo codes can't be created, and any outstanding codes no longer work.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(spacing: DesignConstants.Spacing.step2x) {
                if isCurrentUserSuperAdmin {
                    Button {
                        onLock()
                    } label: {
                        Text(isLocked ? "Unlock" : "Lock convo")
                    }
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorBackgroundInverted))
                    .accessibilityIdentifier(isLocked ? "unlock-convo-button" : "lock-convo-button")

                    Button {
                        onDismiss()
                    } label: {
                        Text(isLocked ? "Keep locked" : "Cancel")
                    }
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("locked-convo-dismiss-button")
                } else {
                    Button {
                        onDismiss()
                    } label: {
                        Text("Got it")
                    }
                    .convosButtonStyle(.rounded(fullWidth: true))
                    .accessibilityIdentifier("locked-convo-got-it-button")
                }
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}

#Preview("Super Admin - Locked") {
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
            isLocked: true,
            onLock: {},
            onDismiss: {}
        )
        .background(.colorBackgroundSurfaceless)
    }
}

#Preview("Super Admin - Unlocked") {
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
            isLocked: false,
            onLock: {},
            onDismiss: {}
        )
        .background(.colorBackgroundSurfaceless)
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
            isLocked: true,
            onLock: {},
            onDismiss: {}
        )
        .background(.colorBackgroundSurfaceless)
    }
}
