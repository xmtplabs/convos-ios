import ConvosComposer
import SwiftUI

/// One page-level component of a Space document, drawn in document order.
///
/// A page is `Page([...])` and its children are whatever the author wrote —
/// the starter's home page is `[Intro, WidgetGrid, AskAgentButton]`. Drawing
/// only the grid drops the prose that introduces it and the action under it,
/// so the whole child list is walked and each component drawn as itself.
///
/// Front-matter is deliberately not drawn here: the web page uses `title` and
/// `description` for the document head, never as visible content, and showing
/// them would put a heading on the page that the page never had.
struct SpacePageContent: View {
    let node: SpaceNode
    let widgetGrid: ([SpaceWidget]) -> AnyView
    let onAsk: () -> Void

    var body: some View {
        switch node.typeName {
        case "Intro": intro
        case "WidgetGrid": grid
        case "AskAgentButton": askAgent
        case "Heading": heading
        case "Text", "Markdown": prose
        case "Section": section
        case "List": bulleted
        case "Hint", "Empty": hint
        default: EmptyView()
        }
    }

    /// Mirrors `.space-intro`: a 32pt headline over its Markdown body.
    @ViewBuilder
    private var intro: some View {
        VStack(alignment: .leading, spacing: SpaceTileStyle.extraSmall) {
            if let headline = node.string("headline") {
                Text(headline)
                    .font(.system(size: 32, weight: .bold))
                    .kerning(-1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let body = SpaceNode(node.props["body"] ?? .null) {
                MarkdownBody(text: body.string("text") ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SpaceTileStyle.large)
    }

    @ViewBuilder
    private var grid: some View {
        widgetGrid(node.children.compactMap(SpaceWidget.init))
    }

    /// Mirrors `.space-ask-agent`: a capsule led by a plus badge, with its note
    /// underneath. The web button asks the agent through the native bridge;
    /// here it is a native action already.
    @ViewBuilder
    private var askAgent: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Button(action: onAsk) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "plus.square.fill")
                        .font(.system(size: 22))
                    Text(node.string("label") ?? "Add anything")
                        .font(.system(size: 17))
                }
                .frame(maxWidth: .infinity)
                .padding(SpaceTileStyle.small)
                .background(
                    RoundedRectangle(cornerRadius: SpaceTileStyle.radius)
                        .fill(SpaceTileStyle.surface)
                )
            }
            .buttonStyle(.plain)
            if let note = node.string("note") {
                Text(note)
                    .font(.system(size: 15))
                    .foregroundStyle(SpaceTileStyle.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, SpaceTileStyle.large)
    }

    @ViewBuilder
    private var heading: some View {
        Text(node.string("text") ?? "")
            .font(.system(size: 28, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var prose: some View {
        MarkdownBody(text: node.string("text") ?? "")
    }

    @ViewBuilder
    private var section: some View {
        VStack(alignment: .leading, spacing: SpaceTileStyle.extraSmall) {
            if let title = node.string("title") {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
            }
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                SpacePageContent(node: child, widgetGrid: widgetGrid, onAsk: onAsk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var bulleted: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            ForEach(Array(node.strings("items").enumerated()), id: \.offset) { _, item in
                Text(verbatim: "• \(item)")
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var hint: some View {
        Text(node.string("message") ?? "")
            .font(.system(size: 15))
            .foregroundStyle(SpaceTileStyle.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Markdown subset a Space document may carry, as paragraphs.
///
/// The web pipeline is a pinned, sanitised micromark subset. `AttributedString`
/// covers the inline part of it; blank-line paragraph breaks are split here
/// because a single `Text` collapses them, and the page's rhythm comes from
/// those gaps.
private struct MarkdownBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: SpaceTileStyle.small) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(attributed(paragraph))
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paragraphs: [String] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func attributed(_ paragraph: String) -> AttributedString {
        // Inline-only: a paragraph is already one block, and full Markdown
        // parsing here would let a heading or list through the sanitised subset.
        (try? AttributedString(
            markdown: paragraph,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(paragraph)
    }
}
