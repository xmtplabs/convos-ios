import ConvosComposer
import SwiftUI

/// What a tile draws inside its card.
///
/// A `Widget`'s children are its preview, and the preview's component name is
/// the tile's type: `NotesPreview` is the notes tile, `EventsPreview` the
/// calendar. Rendering falls through three tiers, so a Space is never blocked
/// on this file catching up with it:
///
/// 1. A preview this build knows, drawn as itself.
/// 2. An unknown preview built from generic primitives — a list, a metric, a
///    line of text — drawn generically. Most agent-invented tiles land here.
/// 3. Anything else: the route, which still opens the real page on tap.
struct SpaceWidgetPreview: View {
    let widget: SpaceWidget
    let preview: SpaceNode?

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

    @ViewBuilder
    private var notes: some View {
        // Titles first, count second: the reader recognises a note by its name,
        // and the count only says how much more there is.
        let titles = preview?.nodes("notes").compactMap { $0.string("title") } ?? []
        TileRows(
            heading: preview?.int("count").map { "\($0)" },
            lines: titles,
            empty: "No notes yet"
        )
    }

    @ViewBuilder
    private var directory: some View {
        let members = preview?.rows("members") ?? []
        let names = members.compactMap { $0.string("name") }
        VStack(spacing: DesignConstants.Spacing.step2x) {
            HStack(spacing: -Constant.avatarOverlap) {
                ForEach(Array(names.prefix(Constant.avatarLimit).enumerated()), id: \.offset) { _, name in
                    InitialAvatar(name: name)
                }
            }
            if members.count > names.prefix(Constant.avatarLimit).count {
                Text(verbatim: "+\(members.count - Constant.avatarLimit)")
                    .font(.caption2)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var reminders: some View {
        let rows = preview?.rows("reminders") ?? []
        TileChecks(
            rows: rows.map { ($0.string("label") ?? "", $0.bool("done") ?? false) },
            empty: "Nothing due"
        )
    }

    @ViewBuilder
    private var checklist: some View {
        let rows = preview?.rows("items") ?? []
        TileChecks(
            rows: rows.map { ($0.string("label") ?? "", $0.bool("done") ?? false) },
            empty: "Nothing to do"
        )
    }

    @ViewBuilder
    private var events: some View {
        let items = preview?.nodes("events") ?? []
        TileRows(
            heading: preview?.strings("days").first,
            lines: items.compactMap { $0.string("title") },
            empty: "Nothing planned"
        )
    }

    // MARK: - Tier 2

    @ViewBuilder
    private var list: some View {
        TileRows(heading: nil, lines: preview?.strings("items") ?? [], empty: "Empty")
    }

    @ViewBuilder
    private var metric: some View {
        VStack(spacing: DesignConstants.Spacing.stepHalf) {
            Text(preview?.string("value") ?? "—")
                .font(.title.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            if let label = preview?.string("label") {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var text: some View {
        Text(preview?.string("text") ?? "")
            .font(.footnote)
            .foregroundStyle(.colorTextPrimary)
            .multilineTextAlignment(.center)
            .padding(DesignConstants.Spacing.step3x)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tier 3

    @ViewBuilder
    private var unknown: some View {
        VStack(spacing: DesignConstants.Spacing.stepHalf) {
            if let count = widget.itemCount {
                Text(verbatim: "\(count)")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
            }
            Text(widget.route)
                .font(.caption2.monospaced())
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum Constant {
        static let avatarLimit: Int = 3
        static let avatarOverlap: CGFloat = 8.0
    }
}

/// A heading with a few lines under it — the shape most previews reduce to.
private struct TileRows: View {
    let heading: String?
    let lines: [String]
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            if let heading {
                Text(heading)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
            }
            if lines.isEmpty {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.colorTextSecondary)
            } else {
                ForEach(Array(lines.prefix(Constant.lineLimit).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DesignConstants.Spacing.step3x)
    }

    private enum Constant {
        static let lineLimit: Int = 3
    }
}

/// Labelled rows with a done state, for reminders and checklists.
private struct TileChecks: View {
    let rows: [(label: String, done: Bool)]
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            if rows.isEmpty {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.colorTextSecondary)
            } else {
                ForEach(Array(rows.prefix(Constant.rowLimit).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(row.done ? Color.colorTextSecondary : .colorTextSecondary)
                        Text(row.label)
                            .font(.caption2)
                            .foregroundStyle(.colorTextPrimary)
                            .strikethrough(row.done)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DesignConstants.Spacing.step3x)
    }

    private enum Constant {
        static let rowLimit: Int = 3
    }
}

/// A member's initial, standing in until avatars are loaded.
private struct InitialAvatar: View {
    let name: String

    var body: some View {
        Circle()
            .fill(Color.colorBackgroundSubtle)
            .overlay {
                Circle().strokeBorder(Color.colorBorderSubtle)
            }
            .overlay {
                Text(initial)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.colorTextSecondary)
            }
            .frame(width: Constant.size, height: Constant.size)
    }

    private var initial: String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    private enum Constant {
        static let size: CGFloat = 32.0
    }
}
