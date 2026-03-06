import ConvosCore
import SwiftUI

struct AgentOutOfCreditsView: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            ProfileAvatarView(profile: profile, profileImage: nil, useSystemPlaceholder: false)
                .frame(width: 16, height: 16)

            Text("\(profile.displayName) is out of processing power")
                .font(.caption)
                .foregroundStyle(.colorTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step2x)
    }
}
