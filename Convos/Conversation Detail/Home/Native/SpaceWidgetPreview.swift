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
    /// Where a committed asset path resolves against, for tiles that draw one.
    let fileBase: URL?
    let onInvite: () -> Void

    var body: some View {
        switch preview?.typeName {
        case "NotesPreview": notes
        case "DirectoryPreview": directory
        case "RemindersPreview": reminders
        case "ChecklistPreview": checklist
        case "EventsPreview": events
        case "PhotosPreview": photos
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

    /// Mirrors `RemindersPreview`. A finished reminder is neither shown nor
    /// counted — the tile is about what is still open — so the whole collection
    /// arrives and the filtering happens here, exactly as the component does it.
    @ViewBuilder
    private var reminders: some View {
        let open = (preview?.rows("reminders") ?? []).filter { ($0.bool("done") ?? false) == false }
        TileColumn {
            TileHeaderBar(
                icon: nil,
                name: "Reminders",
                count: "\(open.count)",
                background: SpaceTileStyle.fillPrimary
            )
            ForEach(Array(open.prefix(Constant.rowLimit).enumerated()), id: \.offset) { _, row in
                CheckRow(label: row.string("label") ?? "")
            }
        }
    }

    /// Mirrors `ChecklistPreview`, which keeps its done rows and shows the
    /// checkbox filled — the point of a checklist is the progress through it.
    @ViewBuilder
    private var checklist: some View {
        let items = preview?.rows("items") ?? []
        TileColumn {
            TileHeaderBar(
                icon: nil,
                name: preview?.string("name") ?? "Checklist",
                count: "\(items.count)",
                background: SpaceTileStyle.fillPrimary
            )
            ForEach(Array(items.prefix(Constant.rowLimit).enumerated()), id: \.offset) { _, row in
                CheckRow(label: row.string("label") ?? "", done: row.bool("done") ?? false)
            }
        }
    }

    /// Mirrors `EventsPreview`: no header bar, events grouped under the day
    /// they fall on, consecutive events on one day sharing a heading.
    @ViewBuilder
    private var events: some View {
        let items = Array((preview?.nodes("events") ?? []).prefix(Constant.rowLimit))
        let days = Array((preview?.strings("days") ?? []).prefix(Constant.rowLimit))
        if items.isEmpty {
            TileColumn { TileHintRow("Agents add events for the group") }
        } else {
            TileColumn {
                ForEach(Array(Self.dayGroups(days: days, count: items.count).enumerated()), id: \.offset) { index, group in
                    if !group.day.isEmpty {
                        DayHeader(day: group.day, isFirst: index == 0)
                    }
                    ForEach(group.positions, id: \.self) { position in
                        EventSlot(event: items[position])
                    }
                }
            }
            .padding(.top, 3.0)
        }
    }

    /// Groups consecutive positions that share a day, by the date part alone so
    /// two times on one day sit under one heading.
    private static func dayGroups(days: [String], count: Int) -> [(day: String, positions: [Int])] {
        var groups: [(day: String, positions: [Int])] = []
        for position in 0..<count {
            let day = String((days.indices.contains(position) ? days[position] : "").prefix(10))
            if var last = groups.last, last.day == day {
                last.positions.append(position)
                groups[groups.count - 1] = last
            } else {
                groups.append((day: day, positions: [position]))
            }
        }
        return groups
    }

    /// Mirrors `PhotosPreview`: the album's newest photo bled to the edges with
    /// its name and count floating over it.
    @ViewBuilder
    private var photos: some View {
        let album = preview?.string("album") ?? ""
        if album.isEmpty {
            TileColumn { TileHintRow("Photos the group shares land here") }
        } else {
            ZStack(alignment: .bottom) {
                if let cover = assetURL(preview?.string("cover")) {
                    AsyncImage(url: cover) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        SpaceTileStyle.fillMinimal
                    }
                    .clipped()
                }
                // The `over` header variant: no bar, just the text on the media.
                TileHeaderBar(
                    icon: nil,
                    name: album,
                    count: preview?.int("count").map { "\($0)" },
                    background: .clear
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Resolves a committed asset path against the deployment's file base.
    private func assetURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard let base = fileBase else { return nil }
        return URL(string: path, relativeTo: base)
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
    let icon: String?
    let name: String
    let count: String?
    let background: Color

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
            }
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
        // `.space-tile-hint` sets no line clamp, so the hint wraps inside the
        // room the tile has rather than truncating on its first line.
        Text(message)
            .font(SpaceTileStyle.hintFont)
            .foregroundStyle(SpaceTileStyle.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpaceTileStyle.small)
            .padding(.vertical, SpaceTileStyle.extraSmall)
    }
}

/// Mirrors `.space-tile-reminder` / `.space-tile-checklist-row`: a 22pt circle
/// and a label on a 41pt row.
private struct CheckRow: View {
    let label: String
    var done: Bool = false

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Circle()
                .strokeBorder(SpaceTileStyle.borderSecondary, lineWidth: 1.5)
                .overlay {
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SpaceTileStyle.borderSecondary)
                    }
                }
                .frame(width: 22.0, height: 22.0)
            Text(label)
                .font(SpaceTileStyle.bodyFont)
                .foregroundStyle(SpaceTileStyle.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: SpaceTileStyle.rowHeight)
        .padding(.horizontal, SpaceTileStyle.small)
    }
}

/// Mirrors `.space-tile-day-header`: the day in lava, its date beside it, and
/// a tighter second heading when another day follows.
private struct DayHeader: View {
    let day: String
    let isFirst: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
            Text(Self.label(for: day))
                .foregroundStyle(SpaceTileStyle.lava)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isFirst, let date = Self.date(for: day) {
                Text(date)
                    .foregroundStyle(SpaceTileStyle.textSecondary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: isFirst ? 13 : 12))
        .padding(.horizontal, SpaceTileStyle.small)
        .padding(.vertical, isFirst ? 11.0 : 8.0)
    }

    /// What a reader would call this day, when they would call it anything —
    /// and its calendar date when they would not. A far-off Saturday is "Aug 29",
    /// not "Saturday", because two different Saturdays read the same otherwise.
    static func label(for day: String) -> String {
        SpaceDay.name(of: day) ?? SpaceDay.dateLabel(of: day) ?? day
    }

    /// Only a named day carries its date beside it. Where the label is already
    /// the date, printing it twice says the same thing twice.
    static func date(for day: String) -> String? {
        guard SpaceDay.name(of: day) != nil else { return nil }
        return SpaceDay.dateLabel(of: day)
    }
}

/// Mirrors `.space-tile-event`: a tinted card carrying the title and its time.
private struct EventSlot: View {
    let event: SpaceNode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(event.string("title") ?? "")
                .font(SpaceTileStyle.bodyFont)
                .foregroundStyle(SpaceTileStyle.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let when {
                Text(when)
                    .font(SpaceTileStyle.hintFont)
                    .foregroundStyle(SpaceTileStyle.textPrimary)
                    .opacity(0.6)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.stepX)
        .background(
            RoundedRectangle(cornerRadius: SpaceTileStyle.eventRadius)
                .fill(SpaceTileStyle.lava.opacity(0.15))
        )
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .padding(.bottom, DesignConstants.Spacing.stepX)
    }

    /// The clock written in `start` when it carries one, the note otherwise.
    private var when: String? {
        if let start = event.string("start"), let time = Self.time(from: start) {
            return time
        }
        let note = event.string("timeNote") ?? ""
        return note.isEmpty ? nil : note
    }

    private static func time(from start: String) -> String? {
        SpaceDay.timeLabel(of: start)
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
