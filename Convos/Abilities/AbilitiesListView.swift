import ConvosCore
import SwiftUI

/// The V2 abilities catalog list (account level), reachable from the
/// App Settings connections row when the Abilities V2 feature flag is on.
/// Placeholder shell: the searchable catalog with entitlement states lands
/// on top of this entry point.
struct AbilitiesListView: View {
    var body: some View {
        List {
            headerSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Abilities")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
                Text("Give agents new powers in your convos")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
        .listRowSpacing(0.0)
        .listRowInsets(.all, DesignConstants.Spacing.step2x)
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }
}

#Preview {
    NavigationStack {
        AbilitiesListView()
    }
}
