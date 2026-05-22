import SwiftUI

struct ExpiryLabel: View {
    let secondsRemaining: Int

    var body: some View {
        Text("Expires in \(secondsRemaining)s")
            .font(.caption)
            .foregroundStyle(.colorTextTertiary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.linear(duration: 0.3), value: secondsRemaining)
            .accessibilityIdentifier("pairing-countdown")
    }
}
