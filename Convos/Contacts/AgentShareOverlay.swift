import ConvosCore
import SwiftUI

/// The agent contact card's share flow: a QR "agent code" encoding the agent
/// template's published URL, with the template emoji over a `.colorLava`
/// circle in the center and the template name as the header. A thin wrapper
/// over the reusable `QRCodeCardOverlay`, mirroring the conversation
/// "Convos code" flow.
struct AgentShareOverlay: View {
    let displayName: String
    let emoji: String?
    let publishedURLString: String
    @Binding var isPresented: Bool

    var body: some View {
        QRCodeCardOverlay(
            encodedURLString: publishedURLString,
            isPresented: $isPresented,
            topPadding: DesignConstants.Spacing.step6x,
            ignoresTopSafeArea: true,
            header: {
                Text(displayName)
                    .kerning(1.0)
            },
            center: {
                centerChip
            }
        )
    }

    private var centerChip: some View {
        ZStack {
            Circle()
                .fill(.colorLava)
            if let emoji {
                GeometryReader { proxy in
                    let side: CGFloat = min(proxy.size.width, proxy.size.height)
                    Text(emoji)
                        .font(.system(size: side * 0.5, weight: .semibold, design: .rounded))
                        .frame(width: side, height: side)
                }
            }
        }
    }
}
