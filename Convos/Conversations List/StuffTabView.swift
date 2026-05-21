import SwiftUI

/// Placeholder for the cross-conversation "Stuff" tab. Today this tab will
/// eventually mirror what `StuffListView` renders inside a single
/// conversation, but aggregated across every conversation the user is in.
/// Until that aggregation UI is designed we ship a centered text stand-in
/// so the tab bar shell can ship without blocking on the real screen.
struct StuffTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.colorTextSecondary)
                Text("Stuff")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Photos, files, and more from across every convo will show up here.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.horizontal, DesignConstants.Spacing.step8x)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundSurfaceless)
        }
    }
}

#Preview {
    StuffTabView()
}
