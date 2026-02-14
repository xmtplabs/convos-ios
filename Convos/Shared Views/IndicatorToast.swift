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
            VStack(alignment: .leading, spacing: 2) {
                Text("Reveal mode")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)

                Text("Blur incoming pics")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { !isAutoReveal },
                set: { isAutoReveal = !$0 }
            ))
                .labelsHidden()
                .padding(.trailing, DesignConstants.Spacing.stepX)
        }
        .padding(.leading, DesignConstants.Spacing.step4x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .fixedSize()
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
