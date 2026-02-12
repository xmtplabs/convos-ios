import SwiftUI

struct SetupQuicknameSuccessView: View {
    var body: some View {
        Group {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "lanyardcard.fill")
                    .foregroundStyle(.colorLava)

                Text("Quickname saved")
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.vertical, DesignConstants.Spacing.step3HalfX)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
        .background(
            Capsule()
                .fill(.colorFillMinimal)
        )
    }
}

#Preview {
    SetupQuicknameSuccessView()
}

struct SetupQuicknameView: View {
    let action: () -> Void
    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "lanyardcard.fill")
                    .foregroundStyle(.colorLava)
                    .accessibilityHidden(true)
                Text("Add your name for this convo")
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimaryInverted)
            }
            .padding(.vertical, DesignConstants.Spacing.step3HalfX)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .background(
                Capsule()
                    .fill(.colorBackgroundInverted)
            )
        }
        .accessibilityLabel("Add your name for this convo")
        .accessibilityIdentifier("setup-quickname-button")
        .transition(.blurReplace)
        .hoverEffect(.lift)
        .padding(.vertical, DesignConstants.Spacing.step4x)
    }
}

#Preview {
    VStack(spacing: 20) {
        SetupQuicknameView {}
    }
    .padding()
}
