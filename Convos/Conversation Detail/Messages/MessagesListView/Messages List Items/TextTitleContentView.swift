import ConvosCore
import SwiftUI

struct TextTitleContentView: View {
    let title: String
    let profile: Profile?
    var agentVerification: AgentVerification = .unverified
    var onTap: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: DesignConstants.Spacing.stepX) {
            if let profile {
                MessageAvatarView(
                    profile: profile,
                    size: 16.0,
                    agentVerification: agentVerification
                )
            }

            Text(title)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(profile != nil ? .colorTextPrimary : .colorTextSecondary)
        }
        .transition(.blurReplace)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)

        if let onTap {
            let action = { onTap() }
            Button(action: action) {
                content
            }
        } else {
            content
        }
    }
}

#Preview {
    TextTitleContentView(title: "Sample Title", profile: .mock())
}

#Preview {
    TextTitleContentView(title: "A Much Longer Title That Should Be Centered", profile: .mock())
}
