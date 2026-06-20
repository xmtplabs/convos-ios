import SwiftUI

/// Always-visible chip shown while the curated prod debug menu is enabled, so a
/// user (or a support agent reviewing a screen recording) can always tell the
/// device is in an elevated-diagnostics state. Rendered app-wide from the root
/// container; it does not gate any data on its own.
struct DebugModeIndicator: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Debug mode ON")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.orange)
            )
            .padding(.bottom, 8)
            .accessibilityIdentifier("debug-mode-indicator")
            .accessibilityLabel("Debug mode is on")
        }
        .allowsHitTesting(false)
        .ignoresSafeArea(.keyboard)
    }
}

#Preview {
    DebugModeIndicator()
}
