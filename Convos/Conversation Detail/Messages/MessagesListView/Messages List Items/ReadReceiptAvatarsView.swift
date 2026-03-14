import ConvosCore
import SwiftUI

struct ReadReceiptAvatarsView: View {
    let profiles: [Profile]

    @State private var contentWidth: CGFloat = 0

    private let avatarSize: CGFloat = 16
    private let maxWidth: CGFloat = 120

    private var needsScrolling: Bool {
        contentWidth > maxWidth
    }

    private var avatarStack: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            ForEach(profiles) { profile in
                ProfileAvatarView(
                    profile: profile,
                    profileImage: nil,
                    useSystemPlaceholder: false
                )
                .frame(width: avatarSize, height: avatarSize)
            }
        }
    }

    var body: some View {
        Group {
            if needsScrolling {
                ScrollView(.horizontal, showsIndicators: false) {
                    avatarStack
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: maxWidth)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(
                            colors: [.black, .black.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: DesignConstants.Spacing.step2x)
                    }
                )
            } else {
                avatarStack
            }
        }
        .background(
            avatarStack
                .fixedSize()
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.preference(key: AvatarContentWidthKey.self, value: geo.size.width)
                })
        )
        .onPreferenceChange(AvatarContentWidthKey.self) { width in
            contentWidth = width
        }
        .accessibilityIdentifier("read-receipt-avatars")
    }
}

private struct AvatarContentWidthKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
