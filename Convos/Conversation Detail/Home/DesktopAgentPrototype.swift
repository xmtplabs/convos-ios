import ConvosComposer
import ConvosCore
import SwiftUI

struct DesktopPrototypeLink: Identifiable, Equatable {
    enum Kind: String {
        case document = "Document"
        case design = "Design"
        case website = "Website"

        var symbolName: String {
            switch self {
            case .document: "doc.text.fill"
            case .design: "paintbrush.pointed.fill"
            case .website: "globe"
            }
        }

        var tint: Color {
            switch self {
            case .document: .colorBlue
            case .design: Color(red: 0.58, green: 0.27, blue: 0.80)
            case .website: .colorLava
            }
        }
    }

    let id: String
    let title: String
    let host: String
    let url: URL?
    let imageURL: URL?
    let kind: Kind
    let isSample: Bool

    init(
        id: String,
        title: String,
        host: String,
        url: URL?,
        imageURL: URL?,
        kind: Kind,
        isSample: Bool = false
    ) {
        self.id = id
        self.title = title
        self.host = host
        self.url = url
        self.imageURL = imageURL
        self.kind = kind
        self.isSample = isSample
    }

    init(messageId: String, preview: LinkPreview) {
        let url: URL? = preview.resolvedURL
        let host: String = preview.siteName ?? preview.displayHost
        self.init(
            id: "message:\(messageId)",
            title: preview.title ?? preview.displayHost,
            host: host,
            url: url,
            imageURL: preview.imageURL.flatMap(URL.init(string:)),
            kind: Self.kind(for: url)
        )
    }

    static func displayLinks(from messages: [MessagesListItemType]) -> [DesktopPrototypeLink] {
        var links: [DesktopPrototypeLink] = []
        var seenURLs: Set<String> = []

        for item in messages {
            guard case .messages(let group) = item else { continue }
            for message in group.messages {
                guard case .linkPreview(let preview) = message.content,
                      seenURLs.insert(preview.url).inserted else { continue }
                links.append(.init(messageId: message.id, preview: preview))
            }
        }

        for sample in samples where links.count < 3 && seenURLs.insert(sample.id).inserted {
            links.append(sample)
        }
        return Array(links.prefix(6))
    }

    private static func kind(for url: URL?) -> Kind {
        let host: String = url?.host?.lowercased() ?? ""
        if host.contains("docs.google") || host.contains("notion") || host.contains("drive.google") {
            return .document
        }
        if host.contains("figma") || host.contains("canva") {
            return .design
        }
        return .website
    }

    private static let samples: [DesktopPrototypeLink] = [
        .init(
            id: "sample:quarterly-plan",
            title: "Q3 trip plan and decisions",
            host: "Google Docs",
            url: URL(string: "https://docs.google.com/document/"),
            imageURL: nil,
            kind: .document,
            isSample: true
        ),
        .init(
            id: "sample:tokyo-redesign",
            title: "Tokyo Home redesign",
            host: "Figma",
            url: URL(string: "https://www.figma.com/"),
            imageURL: nil,
            kind: .design,
            isSample: true
        ),
        .init(
            id: "sample:restaurant-list",
            title: "Friday night shortlist",
            host: "The Infatuation",
            url: URL(string: "https://www.theinfatuation.com"),
            imageURL: nil,
            kind: .website,
            isSample: true
        ),
    ]
}

struct DesktopAgentPrototypeShelf: View {
    let links: [DesktopPrototypeLink]
    let agent: AgentChatLane
    let onOpenLink: (DesktopPrototypeLink) -> Void
    let onEditLink: (DesktopPrototypeLink) -> Void
    let onEditHome: () -> Void

    @State private var isExpanded: Bool = true

    private var realLinkCount: Int {
        links.lazy.filter { !$0.isSample }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: DesignConstants.Spacing.step3x) {
                        ForEach(links) { link in
                            linkCard(link)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.bottom, DesignConstants.Spacing.step3x)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 8)
        .animation(.snappy(duration: 0.28), value: isExpanded)
        .accessibilityIdentifier("desktop-agent-link-shelf")
    }

    private var header: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "link")
                        .font(.footnote.weight(.semibold))
                    Text("From the chat")
                        .font(.body.weight(.semibold))
                    Text(realLinkCount == 0 ? "Demo" : "\(realLinkCount)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                }
                .foregroundStyle(.colorTextPrimary)
                .frame(minHeight: 48)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse chat links" : "Expand chat links")

            Spacer(minLength: 0)

            Button(action: onEditHome) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    AgentChatLaneAvatar(lane: agent, size: 28)
                    Text("Edit Home")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.colorTextPrimary)
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .frame(minHeight: 44)
                .background(.colorFillSubtle, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(agent.name) with a Home editing prompt")
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
    }

    private func linkCard(_ link: DesktopPrototypeLink) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            HStack {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    linkThumbnail(link)
                    if link.isSample {
                        Text("Demo")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.colorTextSecondary)
                            .padding(.horizontal, DesignConstants.Spacing.step2x)
                            .frame(minHeight: 22)
                            .background(.colorBackgroundRaisedSecondary, in: .capsule)
                    }
                }
                Spacer(minLength: DesignConstants.Spacing.step2x)
                Button {
                    onEditLink(link)
                } label: {
                    AgentChatLaneAvatar(lane: agent, size: 30)
                        .overlay {
                            Circle().stroke(Color.colorBorderSubtle, lineWidth: 1)
                        }
                        .contentShape(.circle)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(link.title) with \(agent.name)")
            }

            Button {
                onOpenLink(link)
            } label: {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(link.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(link.host)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this link")
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(width: 180, height: 132, alignment: .topLeading)
        .background(.colorFillSubtle, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func linkThumbnail(_ link: DesktopPrototypeLink) -> some View {
        if let imageURL = link.imageURL {
            AsyncImage(url: imageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                linkKindIcon(link)
            }
            .frame(width: 34, height: 34)
            .clipShape(.rect(cornerRadius: 8))
        } else {
            linkKindIcon(link)
        }
    }

    private func linkKindIcon(_ link: DesktopPrototypeLink) -> some View {
        Image(systemName: link.kind.symbolName)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(link.kind.tint)
            .frame(width: 34, height: 34)
            .background(link.kind.tint.opacity(0.12), in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
