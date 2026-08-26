import ConvosComposer
import SwiftUI

/// What a tile draws inside its card.
///
/// A `Widget`'s children are its preview, and the preview's component name is
/// the tile's type: `NotesPreview` is the notes tile, `DirectoryPreview` the
/// members grid. Each one mirrors the component of the same name in the Space
/// SDK, down to the stylesheet's own metrics, so the tab reads the same as the
/// page it replaces.
///
/// Rendering falls through three tiers, so a Space is never blocked on this
/// file catching up with it:
///
/// 1. A preview this build knows, drawn as itself.
/// 2. An unknown preview built from generic primitives — a list, a metric, a
///    line of text — drawn generically. Most agent-invented tiles land here.
/// 3. Anything else: the route, which still opens the real page on tap.
struct SpaceWidgetPreview: View {
    let widget: SpaceWidget
    let preview: SpaceNode?
    let onInvite: () -> Void

    var body: some View {
        switch preview?.typeName {
        case "NotesPreview": notes
        case "DirectoryPreview": directory
        case "RemindersPreview": reminders
        case "ChecklistPreview": checklist
        case "EventsPreview": events
        case "WidgetList": list
        case "WidgetMetric": metric
        case "WidgetText": text
        default: unknown
        }
    }

    // MARK: - Tier 1

    /// Mirrors `NotesPreview`: a red header carrying the count, up to three
    /// rows, and a hint in whatever room is left over.
    @ViewBuilder
    private var notes: some View {
        let titles = (preview?.nodes("notes") ?? []).compactMap { $0.string("title") }
        let shown = Array(titles.prefix(Constant.rowLimit))
        TileColumn {
            TileHeaderBar(
                icon: "folder",
                name: "Notes",
                count: preview?.int("count").map { "\($0)" },
                background: SpaceTileStyle.notes
            )
            ForEach(Array(shown.enumerated()), id: \.offset) { _, title in
                TileTextRow(title)
            }
            if shown.count < Constant.rowLimit {
                TileHintRow("Agents draft notes for the group")
            }
        }
    }

    /// Mirrors `DirectoryPreview`: a two-by-two grid of 56pt avatars, the last
    /// cell standing in for a larger group, and adding someone in the room left.
    @ViewBuilder
    private var directory: some View {
        let members = preview?.rows("members") ?? []
        let beyond = members.count > Constant.memberCells
            ? members.count - (Constant.memberCells - 1)
            : 0
        let shown = Array(members.prefix(beyond > 0 ? Constant.memberCells - 1 : Constant.memberCells))
        let spare = Constant.memberCells - shown.count - (beyond > 0 ? 1 : 0)
        let columns = [
            GridItem(.fixed(SpaceTileStyle.avatarSize), spacing: SpaceTileStyle.small),
            GridItem(.fixed(SpaceTileStyle.avatarSize), spacing: SpaceTileStyle.small)
        ]
        LazyVGrid(columns: columns, spacing: SpaceTileStyle.small) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, member in
                MemberAvatar(name: member.string("name"))
            }
            if beyond > 0 {
                OverflowAvatar()
            }
            if spare > 0 {
                InviteAvatar(action: onInvite)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SpaceTileStyle.small)
    }

    @ViewBuilder
    private var reminders: some View {
        checkRows(preview?.rows("reminders") ?? [], empty: "Nothing due")
    }

    @ViewBuilder
    private var checklist: some View {
        checkRows(preview?.rows("items") ?? [], empty: "Nothing to do")
    }

    @ViewBuilder
    private func checkRows(_ rows: [[String: SpaceValue]], empty: String) -> some View {
        let shown = Array(rows.prefix(Constant.rowLimit))
        TileColumn {
            if shown.isEmpty {
                TileHintRow(empty)
            } else {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Image(systemName: (row.bool("done") ?? false) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(SpaceTileStyle.textTertiary)
                        Text(row.string("label") ?? "")
                            .font(SpaceTileStyle.bodyFont)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(height: SpaceTileStyle.rowHeight)
                    .padding(.horizontal, SpaceTileStyle.small)
                }
            }
        }
    }

    @ViewBuilder
    private var events: some View {
        let items = preview?.nodes("events") ?? []
        let shown = Array(items.prefix(Constant.rowLimit))
        TileColumn {
            if let day = preview?.strings("days").first {
                TileHeaderBar(icon: "calendar", name: day, count: nil, background: SpaceTileStyle.fillPrimary)
            }
            if shown.isEmpty {
                TileHintRow("Nothing planned")
            } else {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, event in
                    TileTextRow(event.string("title") ?? "")
                }
            }
        }
    }

    // MARK: - Tier 2

    @ViewBuilder
    private var list: some View {
        let items = Array((preview?.strings("items") ?? []).prefix(Constant.rowLimit))
        TileColumn {
            if items.isEmpty {
                TileHintRow("Empty")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    TileTextRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var metric: some View {
        VStack(spacing: 2.0) {
            Text(preview?.string("value") ?? "—")
                .font(.system(size: 28, weight: .semibold))
            if let label = preview?.string("label") {
                Text(label)
                    .font(SpaceTileStyle.hintFont)
                    .foregroundStyle(SpaceTileStyle.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var text: some View {
        Text(preview?.string("text") ?? "")
            .font(SpaceTileStyle.bodyFont)
            .multilineTextAlignment(.center)
            .padding(SpaceTileStyle.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tier 3

    @ViewBuilder
    private var unknown: some View {
        VStack(spacing: 2.0) {
            if let count = widget.itemCount {
                Text(verbatim: "\(count)")
                    .font(.system(size: 28, weight: .semibold))
            }
            Text(widget.route)
                .font(SpaceTileStyle.hintFont.monospaced())
                .foregroundStyle(SpaceTileStyle.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, SpaceTileStyle.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum Constant {
        /// `.space-tile-rows` draws at most three.
        static let rowLimit: Int = 3
        /// `MEMBER_TILE_CELLS`
        static let memberCells: Int = 4
    }
}

// MARK: - Shared tile pieces

/// The tile's own stack: pieces from the top, whatever is left below.
private struct TileColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Mirrors `.space-tile-header`.
private struct TileHeaderBar: View {
    let icon: String
    let name: String
    let count: String?
    let background: Color

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(name)
                .font(SpaceTileStyle.headerNameFont)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count {
                Text(count)
                    .font(SpaceTileStyle.bodyFont)
            }
        }
        .foregroundStyle(SpaceTileStyle.onAccent)
        .padding(.horizontal, SpaceTileStyle.large)
        .frame(height: SpaceTileStyle.rowHeight)
        .frame(maxWidth: .infinity)
        .background(background)
    }
}

/// Mirrors `.space-tile-row`.
private struct TileTextRow: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(SpaceTileStyle.bodyFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SpaceTileStyle.small)
        .frame(height: SpaceTileStyle.rowHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpaceTileStyle.borderSubtle)
                .frame(height: 1.0)
        }
    }
}

/// Mirrors `.space-tile-hint`.
private struct TileHintRow: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message)
            .font(SpaceTileStyle.hintFont)
            .foregroundStyle(SpaceTileStyle.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpaceTileStyle.small)
            .padding(.vertical, SpaceTileStyle.extraSmall)
    }
}

/// Mirrors `.space-avatar` / `.space-avatar-initial`.
private struct MemberAvatar: View {
    let name: String?

    var body: some View {
        RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
            .fill(SpaceTileStyle.fillTertiary)
            .overlay {
                Text(initials)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(SpaceTileStyle.onAccent)
            }
            .frame(width: SpaceTileStyle.avatarSize, height: SpaceTileStyle.avatarSize)
    }

    private var initials: String {
        guard let first = name?.first else { return "" }
        return String(first).uppercased()
    }
}

/// Mirrors `.space-avatar-overflow`: three dots standing for the rest.
private struct OverflowAvatar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
            .fill(SpaceTileStyle.fillMinimal)
            .overlay {
                HStack(spacing: 4.0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(SpaceTileStyle.fillTertiary)
                            .frame(width: 6.0, height: 6.0)
                    }
                }
            }
            .frame(width: SpaceTileStyle.avatarSize, height: SpaceTileStyle.avatarSize)
    }
}

/// Mirrors `.space-avatar-invite`, which the web tile shows only where a native
/// transport can open the picker. Here that transport is the app itself.
private struct InviteAvatar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
                .fill(SpaceTileStyle.fillPrimary)
                .overlay {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(SpaceTileStyle.onAccent)
                }
                .frame(width: SpaceTileStyle.avatarSize, height: SpaceTileStyle.avatarSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add someone")
    }
}
