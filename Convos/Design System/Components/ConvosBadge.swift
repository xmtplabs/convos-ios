import SwiftUI

struct ConvosBadge: View {
    let label: String
    var tone: Tone = .neutral
    var size: Size = .regular

    var body: some View {
        Text(label)
            .font(size.font)
            .foregroundStyle(tone.foregroundColor)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .background(tone.backgroundColor, in: .capsule)
            .accessibilityLabel(label)
    }

    enum Tone {
        case neutral
        case subtle
        case accent
        case warning
        case danger

        var foregroundColor: Color {
            switch self {
            case .neutral, .subtle:
                .colorTextSecondary
            case .accent:
                .colorTextPrimaryInverted
            case .warning:
                .colorTextPrimary
            case .danger:
                .colorCaution
            }
        }

        var backgroundColor: Color {
            switch self {
            case .neutral:
                .colorTextSecondary.opacity(0.1)
            case .subtle:
                .colorFillMinimal
            case .accent:
                .colorFillPrimary
            case .warning:
                .colorWarning.opacity(0.18)
            case .danger:
                .colorCaution.opacity(0.08)
            }
        }
    }

    enum Size {
        case regular
        case compact

        var font: Font {
            switch self {
            case .regular:
                DesignConstants.Typography.label
            case .compact:
                .caption2
            }
        }
    }
}

#Preview {
    HStack(spacing: DesignConstants.Spacing.step2x) {
        ConvosBadge(label: "Agent")
        ConvosBadge(label: "quiet", tone: .subtle, size: .compact)
        ConvosBadge(label: "New", tone: .accent)
        ConvosBadge(label: "Pending", tone: .warning)
        ConvosBadge(label: "Blocked", tone: .danger)
    }
    .padding()
}
