import SwiftUI

/// The two segments of the invite-code screen's Scan/Invite toggle.
enum ScanInviteSegment: CaseIterable, Hashable {
    case invite
    case scan

    var title: String {
        switch self {
        case .invite: return "Invite"
        case .scan: return "Scan"
        }
    }
}

/// Venmo / Cash-App-style segmented control used to flip the invite-code
/// screen between its Invite (QR) and Scan (viewfinder) tabs. A rounded
/// `fillSubtle` track holds a white selection pill that animates between the
/// two equal-width segments. Generic over `ScanInviteSegment` only - it is
/// the single toggle in the invite flow, so it isn't parameterized further.
struct ScanInviteToggle: View {
    @Binding var selection: ScanInviteSegment

    var body: some View {
        GeometryReader { proxy in
            let segmentWidth: CGFloat = (proxy.size.width - Constant.trackPadding * 2.0) / 2.0
            let selectedIndex: CGFloat = selection == .invite ? 0.0 : 1.0
            let pillOffset: CGFloat = segmentWidth * selectedIndex
            ZStack(alignment: .leading) {
                selectionPill(width: segmentWidth)
                    .offset(x: pillOffset)
                HStack(spacing: 0.0) {
                    segmentButton(.invite, width: segmentWidth)
                    segmentButton(.scan, width: segmentWidth)
                }
            }
            .padding(.horizontal, Constant.trackPadding)
            .frame(width: proxy.size.width, height: Constant.trackHeight)
            .background(
                Capsule().fill(DesignConstants.Colors.fillSubtle)
            )
        }
        .frame(height: Constant.trackHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scan-invite-toggle")
    }

    private func selectionPill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Constant.pillCornerRadius)
            .fill(.colorBackgroundSurfaceless)
            .frame(width: width, height: Constant.pillHeight)
            .shadow(color: .black.opacity(0.06), radius: 10.0, x: 0.0, y: 2.0)
    }

    private func segmentButton(_ segment: ScanInviteSegment, width: CGFloat) -> some View {
        let isSelected: Bool = selection == segment
        let weight: Font.Weight = isSelected ? .semibold : .medium
        let action = {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                selection = segment
            }
        }
        return Button(action: action) {
            Text(segment.title)
                .font(.system(size: 14.0, weight: weight))
                .kerning(-0.08)
                .foregroundStyle(.colorTextPrimary)
                .frame(width: width, height: Constant.trackHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scan-invite-toggle-\(segment.title.lowercased())")
    }

    private enum Constant {
        static let trackHeight: CGFloat = 36.0
        static let trackPadding: CGFloat = 4.0
        static let pillHeight: CGFloat = 28.0
        static let pillCornerRadius: CGFloat = 20.0
    }
}

#Preview {
    @Previewable @State var selection: ScanInviteSegment = .invite
    ScanInviteToggle(selection: $selection)
        .frame(width: 283.0)
        .padding()
}
