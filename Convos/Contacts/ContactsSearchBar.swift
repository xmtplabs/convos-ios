import ConvosCore
import SwiftUI

/// Shared search-bar component used by both the contacts list (`ContactsView`)
/// and the contacts picker (`ContactsPickerView`). The two surfaces differ in
/// placeholder copy, so the styling lives here and the placeholder is a
/// configurable knob.
///
/// Visually: a capsule-shaped liquid-glass container with a leading
/// magnifying-glass icon, the text field in the middle, and a trailing action
/// icon on the right. When the field is empty the trailing icon is the filter
/// affordance (`line.3.horizontal.decrease`): if a `filter` binding is supplied
/// it opens a menu that narrows the list to All / People / Agents and -- when
/// `showBlocked` is also supplied -- appends a "Show blocked" toggle that
/// reveals blocked contacts alongside the active audience. Otherwise the icon
/// renders as a static placeholder. Once the user types, the icon is replaced
/// by a clear-X button.
struct ContactsSearchBar: View {
    @Binding var query: String
    let placeholder: String
    let accessibilityIdentifier: String
    private let filter: Binding<ContactsFilter>?
    private let showBlocked: Binding<Bool>?

    init(
        query: Binding<String>,
        placeholder: String,
        accessibilityIdentifier: String,
        filter: Binding<ContactsFilter>? = nil,
        showBlocked: Binding<Bool>? = nil
    ) {
        self._query = query
        self.placeholder = placeholder
        self.accessibilityIdentifier = accessibilityIdentifier
        self.filter = filter
        self.showBlocked = showBlocked
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
                .submitLabel(.search)
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
            emptyQueryAccessory
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

    @ViewBuilder
    private var emptyQueryAccessory: some View {
        if let filter {
            filterMenu(filter)
        } else {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
                .padding(DesignConstants.Spacing.stepX)
        }
    }

    @ViewBuilder
    private func filterMenu(_ filter: Binding<ContactsFilter>) -> some View {
        // Active treatment fires for either the audience narrowing OR the
        // include-blocked toggle, so the user has a single visual cue that
        // *something* about the list is filtered.
        let isShowingBlocked: Bool = showBlocked?.wrappedValue == true
        let isActive: Bool = filter.wrappedValue.isActive || isShowingBlocked
        let iconColor: Color = isActive ? .colorTextPrimary : .colorTextSecondary
        Menu {
            Picker("Filter contacts", selection: filter) {
                ForEach(ContactsFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            if let showBlocked {
                Toggle("Show blocked", isOn: showBlocked)
                    .accessibilityIdentifier("contacts-filter-show-blocked-toggle")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.title3)
                .foregroundStyle(iconColor)
                .padding(DesignConstants.Spacing.stepX)
        }
        .accessibilityLabel("Filter contacts")
        .accessibilityIdentifier("contacts-filter-button")
    }

    private var clearAction: () -> Void {
        { query = "" }
    }
}
