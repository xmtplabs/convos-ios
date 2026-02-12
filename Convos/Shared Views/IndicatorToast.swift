import ConvosCore
import SwiftUI

enum IndicatorToastStyle: Equatable {
    case revealSettings(isAutoReveal: Bool)

    static func == (lhs: IndicatorToastStyle, rhs: IndicatorToastStyle) -> Bool {
        switch (lhs, rhs) {
        case (.revealSettings, .revealSettings):
            return true
        }
    }
}

struct IndicatorToast: View {
    let style: IndicatorToastStyle
    @Binding var isAutoReveal: Bool
    let onDismiss: () -> Void

    var body: some View {
        switch style {
        case .revealSettings:
            RevealSettingsToast(isAutoReveal: $isAutoReveal, onDismiss: onDismiss)
        }
    }
}

struct RevealSettingsToast: View {
    @Binding var isAutoReveal: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 32.0))
                .foregroundStyle(.colorOrange)
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reveal media")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)

                Text(isAutoReveal ? "Automatic" : "Tap to reveal")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }

            Spacer()

            Toggle("", isOn: $isAutoReveal)
                .labelsHidden()
                .padding(.trailing, DesignConstants.Spacing.stepX)
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .frame(maxWidth: 260)
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .task {
            try? await Task.sleep(for: .seconds(5))
            onDismiss()
        }
    }
}

#Preview {
    @Previewable @State var isAutoReveal: Bool = false

    VStack(spacing: 20) {
        RevealSettingsToast(isAutoReveal: $isAutoReveal, onDismiss: {})

        Text("Auto reveal: \(isAutoReveal ? "ON" : "OFF")")
    }
    .padding()
}
