import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactsListView` is the shared sectioned-contacts list used by both
// `ContactsView` (App Settings -> Contacts) and `ContactsPickerView`
// (compose / add-to-conversation picker). The two surfaces previously had
// near-identical `List { Section { ForEach ... } }` shells with their own
// private section-header styling; this view consolidates that scaffolding
// so both surfaces look and behave the same.
//
// Each caller maps its view model's sections into
// `ContactsListView.Section` and supplies a row builder. The list shell
// applies the canonical styling (plain list, hidden scroll background,
// transparent row backgrounds, hidden separators) and stamps each section
// header with `ContactsListSectionHeader`. Callers supply the inner-list
// background since the two surfaces differ there: the contacts browser
// wraps the list in a rounded "card" while the picker uses a flat fill.

/// Canonical alphabetical section shape used by `ContactsListView`. Each
/// caller's view model maps its sections into `[ContactsListSection]`.
struct ContactsListSection<Row: Identifiable>: Identifiable {
    let id: String
    let title: String
    let rows: [Row]
}

/// Sectioned contacts list shared by the contacts browser and the picker.
/// Generic over the caller's row type, the row's rendered content view, and
/// the per-section header. Most callers want the canonical letter header and
/// reach for the convenience initializer below; the picker supplies a custom
/// builder so its "Suggested agents" section can render a richer header.
struct ContactsListView<Row: Identifiable, RowContent: View, SectionHeader: View, ListBackground: View>: View {
    let sections: [ContactsListSection<Row>]
    private let rowContent: (Row) -> RowContent
    private let sectionHeader: (ContactsListSection<Row>) -> SectionHeader
    private let listBackground: ListBackground

    init(
        sections: [ContactsListSection<Row>],
        @ViewBuilder rowContent: @escaping (Row) -> RowContent,
        @ViewBuilder sectionHeader: @escaping (ContactsListSection<Row>) -> SectionHeader,
        @ViewBuilder listBackground: () -> ListBackground
    ) {
        self.sections = sections
        self.rowContent = rowContent
        self.sectionHeader = sectionHeader
        self.listBackground = listBackground()
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                SwiftUI.Section(header: sectionHeader(section)) {
                    ForEach(section.rows) { row in
                        rowContent(row)
                            .listRowBackground(listBackground)
                            .listRowSeparator(.hidden)
                    }
                }
                .id(section.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(listBackground)
    }
}

extension ContactsListView where SectionHeader == ContactsListSectionHeader {
    /// Convenience for callers that just want the canonical letter header.
    init(
        sections: [ContactsListSection<Row>],
        @ViewBuilder rowContent: @escaping (Row) -> RowContent,
        @ViewBuilder listBackground: () -> ListBackground
    ) {
        self.init(
            sections: sections,
            rowContent: rowContent,
            sectionHeader: { ContactsListSectionHeader(title: $0.title) },
            listBackground: listBackground
        )
    }
}

/// Compact section letter ("A", "B", ... "#") rendered above each alphabetical
/// group. Shared across `ContactsView` and `ContactsPickerView`.
struct ContactsListSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.colorTextSecondary)
            .textCase(nil)
            .padding(.leading, DesignConstants.Spacing.step2x)
            .listRowBackground(Color.colorBackgroundRaisedSecondary)
    }
}

/// Header for the trailing "Suggested agents" section, shared by the contacts
/// browser and the picker. A single caption line that aligns with the
/// alphabetical letter headers: the title in `.colorTextSecondary` followed by
/// a "Chat to personalize" hint in `.colorTextTertiary`.
struct SuggestedAgentsSectionHeader: View {
    var body: some View {
        HStack(spacing: 0.0) {
            Text(SuggestedAgentsSection.title)
                .foregroundStyle(.colorTextSecondary)
            Text(" · Chat to personalize")
                .foregroundStyle(.colorTextTertiary)
        }
        .font(.caption)
        .textCase(nil)
        .padding(.leading, DesignConstants.Spacing.step2x)
        .padding(.top, DesignConstants.Spacing.step2x)
        .listRowBackground(Color.colorBackgroundRaisedSecondary)
    }
}
