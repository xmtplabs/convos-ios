import SwiftUI

/// Placeholder content for the iOS 26 `Tab(role: .search)` lane. Search
/// across conversations / contacts hasn't been built yet, so this surface
/// just renders a centered hint until the real search experience ships.
struct SearchTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.colorTextSecondary)
                Text("Search")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Find people, conversations, and stuff across Convos.")
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
    SearchTabView()
}
