import ConvosCore
import SwiftUI

/// Shared search-bar component used by both the contacts list (`ContactsView`)
/// and the contacts picker (`ContactsPickerView`). The two surfaces only
/// differ in placeholder copy, so the styling lives here and the placeholder
/// is the single configurable knob.
///
/// Visually: a capsule-shaped liquid-glass container with a leading
/// magnifying-glass icon, the text field in the middle, and a trailing
/// action icon on the right — `line.3.horizontal` as a placeholder for a
/// future filter affordance when the field is empty, replaced by a clear-X
/// button once the user has typed something.
struct ContactsSearchBar: View {
    @Binding var query: String
    let placeholder: String
    let accessibilityIdentifier: String

    init(
        query: Binding<String>,
        placeholder: String,
        accessibilityIdentifier: String
    ) {
        self._query = query
        self.placeholder = placeholder
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier(accessibilityIdentifier)

            trailingAccessory
        }
        .padding(.leading, DesignConstants.Spacing.step5x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .frame(height: 48.0)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if query.isEmpty {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
                .padding(DesignConstants.Spacing.stepX)
        } else {
            Button(action: clearAction) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.colorTextTertiary)
                    .padding(DesignConstants.Spacing.stepX)
            }
            .accessibilityLabel("Clear search")
        }
    }

    private var clearAction: () -> Void {
        { query = "" }
    }
}
