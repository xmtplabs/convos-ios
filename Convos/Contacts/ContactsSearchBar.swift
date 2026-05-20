import ConvosCore
import SwiftUI

/// Shared search-bar component used by both the contacts list (`ContactsView`)
/// and the contacts picker (`ContactsPickerView`). The two surfaces only
/// differ in placeholder copy, so the styling lives here and the placeholder
/// is the single configurable knob.
///
/// Visually: a pill-shaped capsule filled with `.colorFillMinimal`, with the
/// text field on the left and a clear-X button on the right that only appears
/// once the user has typed something.
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
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier(accessibilityIdentifier)
            if !query.isEmpty {
                Button(action: clearAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.colorTextTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(
            RoundedRectangle(cornerRadius: 16.0)
                .fill(.colorFillMinimal)
        )
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.bottom, DesignConstants.Spacing.step2x)
    }

    private var clearAction: () -> Void {
        { query = "" }
    }
}
