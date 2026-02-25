import SwiftUI

enum ConvosButtonStyleType {
    case outline(fullWidth: Bool)
    case text
    case rounded(fullWidth: Bool, backgroundColor: Color = .colorFillPrimary)
    case action(iconColor: Color = .primary, isDestructive: Bool = false)
}

extension Button {
    func convosButtonStyle(_ styleType: ConvosButtonStyleType) -> some View {
        switch styleType {
        case let .outline(fullWidth):
            return AnyView(self.buttonStyle(OutlineButtonStyle(fullWidth: fullWidth)))
        case .text:
            return AnyView(self.buttonStyle(TextButtonStyle()))
        case let .rounded(fullWidth, backgroundColor):
            return AnyView(self.buttonStyle(RoundedButtonStyle(fullWidth: fullWidth, backgroundColor: backgroundColor)))
        case let .action(iconColor, isDestructive):
            return AnyView(self.buttonStyle(ActionButtonStyle(iconColor: iconColor, isDestructive: isDestructive)))
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    let iconColor: Color
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

struct RoundedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    let fullWidth: Bool
    let backgroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .background(backgroundColor)
            .clipShape(Capsule())
            .foregroundColor(isEnabled ? .colorTextPrimaryInverted : .colorTextTertiary)
    }
}

struct RoundedDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    let fullWidth: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .background(.colorCaution.opacity(0.08))
            .clipShape(Capsule())
            .foregroundColor(isEnabled ? .colorCaution : .colorCaution.opacity(0.75))
    }
}

struct TextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.colorTextSecondary)
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .opacity(isEnabled ? configuration.isPressed ? 0.6 : 1.0 : 0.3)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    let fullWidth: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                    .stroke(.colorBorderSubtle2, lineWidth: 1.0)
            )
            .foregroundColor(isEnabled ? .colorTextPrimary : .colorTextTertiary)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

#Preview {
    VStack(spacing: DesignConstants.Spacing.step4x) {
        Button("Outline Button Style - Disabled") {}
            .convosButtonStyle(.outline(fullWidth: true))
            .disabled(true)

        Button("Outline Button Style - Enabled") {}
            .convosButtonStyle(.outline(fullWidth: true))

        Button("Text Button Style - Disabled") {}
            .convosButtonStyle(.text)
            .disabled(true)

        Button("Text Button Style") {}
            .convosButtonStyle(.text)

        Button("Rounded Button Style") {}
            .convosButtonStyle(.rounded(fullWidth: true))

        Button("Rounded Button Style - Disabled") {}
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(true)

        Button {
            // Action
        } label: {
            HStack {
                Image(systemName: "message.fill")
                    .foregroundColor(.primary)
                Text("Message")
                    .foregroundColor(.primary)
                Spacer()
            }
        }
        .convosButtonStyle(.action())

        Button {
            // Action
        } label: {
            HStack {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                Text("Delete")
                    .foregroundColor(.red)
                Spacer()
            }
        }
        .convosButtonStyle(.action(isDestructive: true))
    }
    .padding(.horizontal, DesignConstants.Spacing.step6x)
}
