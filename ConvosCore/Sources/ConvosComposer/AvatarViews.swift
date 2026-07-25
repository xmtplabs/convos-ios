#if canImport(UIKit)
import ConvosCore
import SwiftUI

public struct AvatarView: View {
    let fallbackName: String
    let cacheableObject: any ImageCacheable
    let placeholderImage: UIImage?
    let placeholderEmoji: String?
    let placeholderImageName: String?
    let agentVerification: AgentVerification
    /// Forwarded to the emoji/monogram fallbacks so they render without a
    /// `GeometryReader` when the caller already knows the avatar size (see
    /// `EmojiAvatarView.size`). Nil keeps the self-sizing path.
    let explicitSize: CGFloat?
    @State private var cachedImage: UIImage?

    public init(
        fallbackName: String,
        cacheableObject: any ImageCacheable,
        placeholderImage: UIImage?,
        placeholderEmoji: String? = nil,
        placeholderImageName: String?,
        agentVerification: AgentVerification = .unverified,
        explicitSize: CGFloat? = nil
    ) {
        self.fallbackName = fallbackName
        self.cacheableObject = cacheableObject
        self.placeholderImage = placeholderImage
        self.placeholderEmoji = placeholderEmoji
        self.placeholderImageName = placeholderImageName
        self.agentVerification = agentVerification
        self.explicitSize = explicitSize
        _cachedImage = State(initialValue: ImageCache.shared.image(for: cacheableObject))
    }

    public var body: some View {
        Group {
            if let image = placeholderImage ?? cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(contentMode: .fill)
            } else if let placeholderEmoji, !placeholderEmoji.isEmpty {
                EmojiAvatarView(emoji: placeholderEmoji, agentVerification: agentVerification, size: explicitSize)
            } else if let placeholderImageName {
                Image(systemName: placeholderImageName)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(contentMode: .fill)
                    .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)
                    .padding(DesignConstants.Spacing.step2x)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .background(agentVerification.avatarBackgroundColor)
            } else {
                MonogramView(name: fallbackName, agentVerification: agentVerification, size: explicitSize)
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
        .clipShape(Circle())
        .cachedImage(for: cacheableObject, into: $cachedImage)
        .accessibilityHidden(true)
    }
}

public struct ProfileAvatarView: View {
    let profile: Profile
    let profileImage: UIImage?
    let useSystemPlaceholder: Bool
    var agentVerification: AgentVerification = .unverified
    /// Forwarded to `AvatarView` so the emoji/monogram fallbacks skip their
    /// `GeometryReader` when the size is already known (clustered avatars).
    var size: CGFloat?

    public init(
        profile: Profile,
        profileImage: UIImage?,
        useSystemPlaceholder: Bool,
        agentVerification: AgentVerification = .unverified,
        size: CGFloat? = nil
    ) {
        self.profile = profile
        self.profileImage = profileImage
        self.useSystemPlaceholder = useSystemPlaceholder
        self.agentVerification = agentVerification
        self.size = size
    }

    public var body: some View {
        AvatarView(
            fallbackName: profile.displayName,
            cacheableObject: profile,
            placeholderImage: profileImage,
            placeholderEmoji: profile.profileEmoji,
            placeholderImageName: useSystemPlaceholder ? "person.crop.circle.fill" : nil,
            agentVerification: profile.isAgent ? agentVerification : .unverified,
            explicitSize: size
        )
    }
}

public struct MonogramView: View {
    private let initials: String
    private let agentVerification: AgentVerification
    /// When set, renders at this exact side length without a `GeometryReader`.
    /// See the matching note on `EmojiAvatarView.size` - the clustered avatar
    /// passes it so each member sub-avatar skips a per-avatar geometry pass.
    private let size: CGFloat?

    public init(text: String, agentVerification: AgentVerification = .unverified, size: CGFloat? = nil) {
        self.initials = text
        self.agentVerification = agentVerification
        self.size = size
    }

    public init(name: String, agentVerification: AgentVerification = .unverified, size: CGFloat? = nil) {
        self.initials = Self.initials(from: name)
        self.agentVerification = agentVerification
        self.size = size
    }

    private var isAgent: Bool {
        agentVerification != .unverified
    }

    public var body: some View {
        if let size {
            circle(side: size).accessibilityHidden(true)
        } else {
            GeometryReader { geometry in
                circle(side: min(geometry.size.width, geometry.size.height))
            }
            .aspectRatio(1.0, contentMode: .fit)
            .accessibilityHidden(true)
        }
    }

    private func circle(side: CGFloat) -> some View {
        Text(initials)
            .font(.system(size: side * 0.5, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.01)
            .lineLimit(1)
            .foregroundColor(.colorTextPrimaryInverted)
            .padding(side * 0.25)
            .frame(width: side, height: side)
            .background {
                if !isAgent {
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, .black.opacity(0.2)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .background(agentVerification.avatarBackgroundColor)
            .clipShape(Circle())
    }

    private static func initials(from fullName: String) -> String {
        let components = fullName.split(separator: " ")
        let initials = components.prefix(2).map { $0.first.map(String.init) ?? "" }
        return initials.joined().uppercased()
    }
}

public struct EmojiAvatarView: View {
    let emoji: String
    var agentVerification: AgentVerification = .unverified
    /// When set, the view renders at this exact side length without a
    /// `GeometryReader`. Callers that already know the avatar size (e.g. the
    /// clustered avatar, which lays its sub-avatars out at computed sizes)
    /// pass it so a scrolling list doesn't pay a geometry-feedback pass per
    /// avatar - a clustered cell otherwise nests one `GeometryReader` per
    /// member. Nil keeps the self-sizing path for callers that only constrain
    /// the avatar with an outer `.frame`.
    var size: CGFloat?

    public init(emoji: String, agentVerification: AgentVerification = .unverified, size: CGFloat? = nil) {
        self.emoji = emoji
        self.agentVerification = agentVerification
        self.size = size
    }

    private var background: Color {
        agentVerification.isVerified ? agentVerification.avatarBackgroundColor : .colorFillMinimal
    }

    public var body: some View {
        if let size {
            circle(side: size).accessibilityHidden(true)
        } else {
            GeometryReader { geometry in
                circle(side: min(geometry.size.width, geometry.size.height))
            }
            .aspectRatio(1.0, contentMode: .fit)
            .accessibilityHidden(true)
        }
    }

    private func circle(side: CGFloat) -> some View {
        Text(emoji)
            .font(.system(size: side * 0.43, weight: .semibold, design: .rounded))
            .frame(width: side, height: side)
            .background(background)
            .clipShape(Circle())
    }
}

public extension AgentVerification {
    var avatarBackgroundColor: Color {
        switch self {
        case .unverified:
            return .colorFillTertiary
        case .verified(let issuer):
            switch issuer {
            case .convos:
                return .colorLava
            case .userOAuth:
                return .colorPurpleMute
            case .unknown:
                return .colorFillSecondary
            }
        }
    }

    var nameColor: Color {
        switch self {
        case .unverified:
            return .secondary
        case .verified(let issuer):
            switch issuer {
            case .convos:
                return .colorLava
            case .userOAuth:
                return .colorPurpleMute
            case .unknown:
                return .colorFillSecondary
            }
        }
    }

    var roleLabel: String? {
        switch self {
        case .unverified:
            return nil
        case .verified(let issuer):
            switch issuer {
            case .convos:
                return "Agent"
            case .userOAuth:
                return "Verified Agent"
            case .unknown:
                return "Verified Agent"
            }
        }
    }
}
#endif
