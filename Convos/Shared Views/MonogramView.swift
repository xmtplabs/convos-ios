import ConvosCore
import SwiftUI

struct MonogramView: View {
    private let initials: String
    private let agentVerification: AgentVerification
    /// When set, renders at this exact side length without a `GeometryReader`.
    /// See the matching note on `EmojiAvatarView.size` - the clustered avatar
    /// passes it so each member sub-avatar skips a per-avatar geometry pass.
    private let size: CGFloat?

    init(text: String, agentVerification: AgentVerification = .unverified, size: CGFloat? = nil) {
        self.initials = text
        self.agentVerification = agentVerification
        self.size = size
    }

    init(name: String, agentVerification: AgentVerification = .unverified, size: CGFloat? = nil) {
        self.initials = Self.initials(from: name)
        self.agentVerification = agentVerification
        self.size = size
    }

    private var isAgent: Bool {
        agentVerification != .unverified
    }

    var body: some View {
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

#Preview {
    VStack {
        MonogramView(name: "Robert Adams")
            .frame(width: 24.0)
        MonogramView(name: "Robert Adams")
            .frame(width: 36.0)
        MonogramView(name: "Robert Adams")
            .frame(width: 52.0)
        MonogramView(name: "Robert Adams")
            .frame(width: 96.0)
        MonogramView(name: "Robert, John, Diana, Jessica, Tom")
            .frame(width: 96.0)
    }
}
