import ConvosCore
import SwiftUI

struct TextTitleContentView: View {
    let title: String
    let profile: Profile?
    var onTap: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: DesignConstants.Spacing.stepX) {
            if let profile {
                ProfileAvatarView(profile: profile, profileImage: nil, useSystemPlaceholder: false)
                    .frame(width: 16.0, height: 16.0)
            }

            Text(title)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
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
