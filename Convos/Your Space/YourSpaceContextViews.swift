import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct YourSpaceContextSection: View {
    let profile: Profile
    let profileImage: UIImage?
    let items: [YourSpaceContextItem]
    let connectionCount: Int
    let recentContext: [YourSpaceUpdate]
    let conversationTitle: (String) -> String?
    let senderName: (String) -> String?
    let onEditCard: () -> Void
    let onBrowse: (YourSpaceContextKind) -> Void
    let onShare: (YourSpaceContextItem) -> Void
    let onAddContext: () -> Void
    let onAddConnections: () -> Void

    private var recentItems: [YourSpaceContextItem] {
        Array(items
            .filter { !$0.isAutomaticallyIndexedUsefulDetail }
            .sorted { $0.date > $1.date }
            .prefix(4))
    }

    private var rememberedItemCount: Int {
        items.count {
            if case .rememberedField = $0.source { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
            sectionHeader

            personalCard

            Button {
                onBrowse(.all)
            } label: {
                HStack(spacing: DesignConstants.Spacing.step3x) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.semibold))
                    Text("Search all your context")
                        .font(.body)
                    Spacer()
                }
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .frame(minHeight: 48)
                .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("your-space-context-search")

            categoryGrid

            usefulDetailsSection

            if !recentItems.isEmpty {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                    Text("Recently added")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 0), spacing: DesignConstants.Spacing.step3x),
                            GridItem(.flexible(minimum: 0)),
                        ],
                        spacing: DesignConstants.Spacing.step3x
                    ) {
                        ForEach(recentItems) { item in
                            YourSpaceContextItemCard(
                                item: item,
                                provenance: provenance(for: item),
                                onShare: { onShare(item) }
                            )
                        }
                    }
                }
            }

            Button {
                onBrowse(.all)
            } label: {
                HStack {
                    Text("See all context")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.colorTextPrimaryInverted)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .frame(minHeight: 52)
                .background(.colorBackgroundInverted, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("your-space-see-all-context")

            Label("Indexed privately from context available on this device", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Me & My Stuff")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Photos, links, files, connections, and useful details—all private until you share them.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }

            Spacer(minLength: DesignConstants.Spacing.step3x)

            Menu {
                Button("Add context", systemImage: "plus.square.on.square") {
                    onAddContext()
                }
                Button("Add connections", systemImage: "link.badge.plus") {
                    onAddConnections()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 44, height: 44)
                    .background(.colorFillMinimal, in: .circle)
            }
            .accessibilityLabel("Add context or connections")
            .accessibilityIdentifier("your-space-context-add-menu")
        }
    }

    private var personalCard: some View {
        Button(action: onEditCard) {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step4x) {
                ProfileAvatarView(
                    profile: profile,
                    profileImage: profileImage,
                    useSystemPlaceholder: true,
                    size: 52
                )
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    HStack {
                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                            Text(profile.displayName)
                                .font(.headline)
                                .foregroundStyle(.colorTextPrimary)
                            Text("My personal card")
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.colorTextSecondary)
                    }

                    if rememberedItemCount > 0 {
                        Text(rememberedItemCount == 1
                            ? "1 remembered detail ready to share"
                            : "\(rememberedItemCount) remembered details ready to share")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.colorTextPrimary)
                            .multilineTextAlignment(.leading)
                    } else if let update = recentContext.first {
                        Text("Recent context from \(update.conversationTitle): \(update.detail)")
                            .font(.subheadline)
                            .foregroundStyle(.colorTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text("Add what you like, how you work, and what Your Space should remember.")
                            .font(.subheadline)
                            .foregroundStyle(.colorTextSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(DesignConstants.Spacing.step4x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                    .stroke(Color.colorBorderSubtle, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("your-space-personal-card")
    }

    private var categoryGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 0), spacing: DesignConstants.Spacing.step3x),
                GridItem(.flexible(minimum: 0)),
            ],
            spacing: DesignConstants.Spacing.step3x
        ) {
            categoryButton(.photo, count: count(.photo))
            categoryButton(.link, count: count(.link))
            categoryButton(.file, count: count(.file) + count(.video) + count(.voice) + count(.note))
            categoryButton(
                title: "Connections",
                systemImage: "point.3.connected.trianglepath.dotted",
                count: connectionCount,
                action: onAddConnections
            )
        }
    }

    private var usefulDetailsSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Useful details")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text("Find details from messages, with who shared them and where they came from.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(spacing: 0) {
                usefulDetailFilterRow(.address)
                Divider().padding(.leading, 56)
                usefulDetailFilterRow(.phone)
                Divider().padding(.leading, 56)
                usefulDetailFilterRow(.email)
                Divider().padding(.leading, 56)
                usefulDetailFilterRow(.useful)
            }
            .background(
                .colorBackgroundRaisedSecondary,
                in: .rect(cornerRadius: DesignConstants.CornerRadius.medium)
            )
        }
    }

    private func usefulDetailFilterRow(_ kind: YourSpaceContextKind) -> some View {
        let itemCount = usefulDetailCount(kind)
        return Button {
            onBrowse(kind)
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: kind.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 36, height: 36)
                    .background(.colorFillMinimal, in: .circle)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(kind == .useful ? "All useful details" : kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text(itemCount == 1 ? "1 detail found" : "\(itemCount) details found")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }

                Spacer(minLength: DesignConstants.Spacing.step2x)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextTertiary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title), \(itemCount) automatically indexed details")
        .accessibilityIdentifier("your-space-useful-details-\(kind.rawValue)")
    }

    private func categoryButton(_ kind: YourSpaceContextKind, count: Int) -> some View {
        categoryButton(
            title: kind.title,
            systemImage: kind.systemImage,
            count: count,
            action: { onBrowse(kind) }
        )
    }

    private func categoryButton(
        title: String,
        systemImage: String,
        count: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                HStack(alignment: .lastTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)
                    Spacer(minLength: DesignConstants.Spacing.step2x)
                    Text("\(count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .padding(DesignConstants.Spacing.step4x)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
    }

    private func count(_ kind: YourSpaceContextKind) -> Int {
        items.count { $0.kind == kind }
    }

    private func usefulDetailCount(_ kind: YourSpaceContextKind) -> Int {
        items.count { item in
            item.isAutomaticallyIndexedUsefulDetail
                && (kind == .useful || item.kind == kind)
        }
    }

    private func provenance(for item: YourSpaceContextItem) -> String {
        if item.isAutomaticallyIndexedUsefulDetail {
            let person: String = item.senderInboxId.flatMap(senderName)
                ?? (item.isMine ? "You" : "Someone")
            let convo: String = item.conversationId.flatMap(conversationTitle) ?? "a convo"
            return "Shared by \(person) in \(convo) · \(item.date.formatted(.relative(presentation: .named)))"
        }
        if let conversationId = item.conversationId,
           let title = conversationTitle(conversationId) {
            if let senderInboxId = item.senderInboxId,
               let name = senderName(senderInboxId) {
                return "\(name) · \(title)"
            }
            return item.isMine ? "You · \(title)" : title
        }
        return "Private in Your Space"
    }
}

/// Home's read-first doorway into the personal library. The entire surface is
/// navigational; editing remains a separate action on the destination screen.
struct YourSpaceMeSummaryCard: View {
    let profile: Profile
    let profileImage: UIImage?
    let items: [YourSpaceContextItem]
    let connectionCount: Int
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
                HStack(alignment: .center, spacing: DesignConstants.Spacing.step4x) {
                    ProfileAvatarView(
                        profile: profile,
                        profileImage: profileImage,
                        useSystemPlaceholder: true,
                        size: 68
                    )
                    .frame(width: 68, height: 68)
                    .overlay {
                        Circle().stroke(Color.colorBorderSubtle, lineWidth: 0.5)
                    }

                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text("Me & My Stuff")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.colorTextPrimary)
                        Text(profile.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: DesignConstants.Spacing.step2x)

                    Image(systemName: "arrow.up.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .frame(width: 44, height: 44)
                        .background(.colorFillMinimal, in: .circle)
                        .accessibilityHidden(true)
                }

                Text("Your photos, links, files, connections, and the useful details Convos helps you keep close.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if dynamicTypeSize.isAccessibilitySize {
                    Text(accessibilitySummary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.colorTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 0) {
                        metric(count(.photo), title: "Photos", symbol: "photo.fill")
                        Divider().frame(height: 38)
                        metric(count(.link), title: "Links", symbol: "link")
                        Divider().frame(height: 38)
                        metric(fileCount, title: "Files", symbol: "folder.fill")
                        Divider().frame(height: 38)
                        metric(connectionCount, title: "Connections", symbol: "point.3.connected.trianglepath.dotted")
                    }
                }

                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "sparkles")
                    Text(usefulDetailCount == 1 ? "1 useful detail saved" : "\(usefulDetailCount) useful details saved")
                    Spacer(minLength: 0)
                    Text("View all")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
            }
            .padding(DesignConstants.Spacing.step5x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.large))
            .overlay {
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                    .stroke(Color.colorBorderSubtle, lineWidth: 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Me & My Stuff, \(accessibilitySummary), \(usefulDetailCount) useful details")
        .accessibilityHint("Opens your private personal library")
        .accessibilityIdentifier("your-space-me-and-my-stuff")
    }

    private var fileCount: Int {
        items.count { [.file, .video, .voice, .note].contains($0.kind) }
    }

    private var usefulDetailCount: Int {
        items.count { $0.isAutomaticallyIndexedUsefulDetail }
    }

    private var accessibilitySummary: String {
        "\(count(.photo)) photos, \(count(.link)) links, \(fileCount) files, and \(connectionCount) connections"
    }

    private func count(_ kind: YourSpaceContextKind) -> Int {
        items.count { $0.kind == kind }
    }

    private func metric(_ value: Int, title: String, symbol: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.colorTextSecondary)
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.colorTextPrimary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

struct YourSpaceContextBrowser: View {
    let items: [YourSpaceContextItem]
    let initialFilter: YourSpaceContextKind
    let conversationTitle: (String) -> String?
    let senderName: (String) -> String?
    let onShare: (YourSpaceContextItem) -> Void
    let onOpenConversation: (String) -> Void
    let onMessageSender: (String) -> Void
    let onAddContext: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var query: String = ""
    @State private var selectedKind: YourSpaceContextKind

    init(
        items: [YourSpaceContextItem],
        initialFilter: YourSpaceContextKind,
        conversationTitle: @escaping (String) -> String?,
        senderName: @escaping (String) -> String?,
        onShare: @escaping (YourSpaceContextItem) -> Void,
        onOpenConversation: @escaping (String) -> Void,
        onMessageSender: @escaping (String) -> Void,
        onAddContext: @escaping () -> Void
    ) {
        self.items = items
        self.initialFilter = initialFilter
        self.conversationTitle = conversationTitle
        self.senderName = senderName
        self.onShare = onShare
        self.onOpenConversation = onOpenConversation
        self.onMessageSender = onMessageSender
        self.onAddContext = onAddContext
        _selectedKind = State(initialValue: initialFilter)
    }

    private var filteredItems: [YourSpaceContextItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { selectedKind == .all || matchesSelectedKind($0) }
            .filter { item in
                guard !normalizedQuery.isEmpty else { return true }
                return item.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || item.detail?.localizedCaseInsensitiveContains(normalizedQuery) == true
                    || item.kind.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || provenance(for: item).localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted { $0.date > $1.date }
    }

    private var usefulItems: [YourSpaceContextItem] {
        filteredItems.filter(\.isAutomaticallyIndexedUsefulDetail)
    }

    private var otherItems: [YourSpaceContextItem] {
        filteredItems.filter { !$0.isAutomaticallyIndexedUsefulDetail }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
                    filterBar

                    if filteredItems.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "No context here yet" : "No results",
                            systemImage: query.isEmpty ? "tray" : "magnifyingglass",
                            description: Text(query.isEmpty
                                ? "Add something here or share it in a convo and it will appear in Your Space."
                                : "Try another search or context type.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        if selectedKind.isUsefulDetailFilter {
                            usefulDetailsList(usefulItems)
                        } else if selectedKind == .all {
                            allContextResults
                        } else {
                            contextGrid(otherItems)
                        }
                    }
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step4x)
            }
            .background(.colorBackgroundSurfaceless)
            .navigationTitle("All context")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Messages, people, convos, details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onAddContext) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add context")
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ForEach(YourSpaceContextKind.browserFilters) { kind in
                    Button {
                        selectedKind = kind
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selectedKind == kind ? .colorTextPrimaryInverted : .colorTextPrimary)
                            .padding(.horizontal, DesignConstants.Spacing.step3x)
                            .frame(minHeight: 36)
                            .background(
                                selectedKind == kind ? Color.colorBackgroundInverted : Color.colorFillMinimal,
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func matchesSelectedKind(_ item: YourSpaceContextItem) -> Bool {
        item.matchesBrowserFilter(selectedKind)
    }

    @ViewBuilder
    private var allContextResults: some View {
        if !usefulItems.isEmpty {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                Text("Useful details")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                usefulDetailsList(usefulItems)
            }
        }

        if !otherItems.isEmpty {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                if !usefulItems.isEmpty {
                    Text("Everything else")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)
                }
                contextGrid(otherItems)
            }
        }
    }

    private func usefulDetailsList(_ items: [YourSpaceContextItem]) -> some View {
        LazyVStack(spacing: DesignConstants.Spacing.step3x) {
            ForEach(items) { item in
                YourSpaceUsefulDetailCard(
                    item: item,
                    sender: senderDisplayName(for: item),
                    conversation: conversationDisplayName(for: item),
                    onShare: { onShare(item) },
                    onOpenConversation: item.conversationId.map { conversationId in
                        { onOpenConversation(conversationId) }
                    },
                    onMessageSender: messageSenderAction(for: item)
                )
            }
        }
    }

    private func contextGrid(_ items: [YourSpaceContextItem]) -> some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(minimum: 150, maximum: 320),
                spacing: DesignConstants.Spacing.step3x
            )],
            spacing: DesignConstants.Spacing.step3x
        ) {
            ForEach(items) { item in
                YourSpaceContextItemCard(
                    item: item,
                    provenance: provenance(for: item),
                    onShare: { onShare(item) }
                )
            }
        }
    }

    private func senderDisplayName(for item: YourSpaceContextItem) -> String {
        item.senderInboxId.flatMap(senderName) ?? (item.isMine ? "You" : "Someone")
    }

    private func conversationDisplayName(for item: YourSpaceContextItem) -> String {
        item.conversationId.flatMap(conversationTitle) ?? "a convo"
    }

    private func messageSenderAction(for item: YourSpaceContextItem) -> (() -> Void)? {
        guard !item.isMine, let senderInboxId = item.senderInboxId else { return nil }
        return { onMessageSender(senderInboxId) }
    }

    private func provenance(for item: YourSpaceContextItem) -> String {
        if item.isAutomaticallyIndexedUsefulDetail {
            let person: String = item.senderInboxId.flatMap(senderName)
                ?? (item.isMine ? "You" : "Someone")
            let convo: String = item.conversationId.flatMap(conversationTitle) ?? "a convo"
            return "Shared by \(person) in \(convo) · \(item.date.formatted(.relative(presentation: .named)))"
        }
        if let conversationId = item.conversationId,
           let title = conversationTitle(conversationId) {
            if let senderInboxId = item.senderInboxId,
               let name = senderName(senderInboxId) {
                return "\(name) · \(title)"
            }
            return item.isMine ? "You · \(title)" : title
        }
        return "Private in Your Space"
    }
}

struct YourSpaceContextItemCard: View {
    let item: YourSpaceContextItem
    let provenance: String
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            YourSpaceContextPreview(item: item)
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.small))

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(2)
                }
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }

            Button(action: onShare) {
                Label("Share", systemImage: "arrowshape.turn.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(.colorFillSubtle, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share \(item.title) to a convo")
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(maxWidth: .infinity, minHeight: 222, alignment: .topLeading)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.medium))
    }
}

private struct YourSpaceUsefulDetailCard: View {
    let item: YourSpaceContextItem
    let sender: String
    let conversation: String
    let onShare: () -> Void
    let onOpenConversation: (() -> Void)?
    let onMessageSender: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            if item.kind == .address {
                YourSpaceContextPreview(item: item)
                    .frame(maxWidth: .infinity)
                    .frame(height: 164)
                    .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.small))
            }

            HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Label(item.kind.title, systemImage: item.kind.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)

                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let onMessageSender {
                    Button(action: onMessageSender) {
                        Image(systemName: "message.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                            .frame(width: 44, height: 44)
                            .background(.colorFillSubtle, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Message \(sender)")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Shared by \(sender)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("\(conversation) · \(item.date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }

            Text(item.detail ?? item.title)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    actionButtons
                }
                VStack(spacing: DesignConstants.Spacing.step2x) {
                    actionButtons
                }
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.medium))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let onOpenConversation {
            Button(action: onOpenConversation) {
                Label("Open convo", systemImage: "bubble.left.and.bubble.right.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Open \(conversation)")
        }

        Button(action: onShare) {
            Label("Share", systemImage: "arrowshape.turn.up.right")
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Share \(item.title) to a convo")
    }
}

struct YourSpacePersonalCardEditor: View {
    let profile: Profile
    let profileImage: UIImage?
    let session: any SessionManagerProtocol
    let recentContext: [YourSpaceUpdate]
    @Binding var rememberedFields: [YourSpaceRememberedField]
    let onShareField: (YourSpaceRememberedField) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @AppStorage("your-space-card-about") private var about: String = ""
    @AppStorage("your-space-card-preferences") private var preferences: String = ""
    @AppStorage("your-space-card-memory") private var memory: String = ""
    @State private var presentingProfileEditor: Bool = false
    @State private var presentingFieldEditor: Bool = false
    @State private var fieldBeingEdited: YourSpaceRememberedField?
    @State private var fieldPendingDeletion: YourSpaceRememberedField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        presentingProfileEditor = true
                    } label: {
                        HStack(spacing: DesignConstants.Spacing.step3x) {
                            ProfileAvatarView(
                                profile: profile,
                                profileImage: profileImage,
                                useSystemPlaceholder: true,
                                size: 48
                            )
                            .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                                Text(profile.displayName)
                                    .foregroundStyle(.colorTextPrimary)
                                Text("Edit name and photo")
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.colorTextTertiary)
                        }
                    }
                }

                Section("About me") {
                    TextField("What should people know?", text: $about, axis: .vertical)
                        .lineLimit(2 ... 6)
                }

                Section("Preferences") {
                    TextField("Places, food, rhythms, formats…", text: $preferences, axis: .vertical)
                        .lineLimit(2 ... 6)
                }

                Section {
                    TextField("Things Your Space should keep handy", text: $memory, axis: .vertical)
                        .lineLimit(2 ... 8)

                    ForEach(rememberedFields) { field in
                        rememberedFieldRow(field)
                    }

                    Button {
                        fieldBeingEdited = nil
                        presentingFieldEditor = true
                    } label: {
                        Label("Add a field", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                } header: {
                    Text("Remember")
                } footer: {
                    Text("Add any title and info. Each field stays private here until you choose a convo to share it with.")
                }

                if !recentContext.isEmpty {
                    Section {
                        ForEach(recentContext.prefix(4)) { update in
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                                Text(update.detail)
                                    .font(.body)
                                Text(update.conversationTitle)
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                                Button("Save to my card") {
                                    appendToMemory(update.detail)
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            .padding(.vertical, DesignConstants.Spacing.stepX)
                        }
                    } header: {
                        Text("Recent context from your convos")
                    } footer: {
                        Text("These are recent updates, not facts about you. Review anything before saving it to your card.")
                    }
                }
            }
            .navigationTitle("Edit Me & My Stuff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $presentingProfileEditor) {
            ProfileSetupSheet(mode: .edit, session: session)
        }
        .sheet(
            isPresented: $presentingFieldEditor,
            onDismiss: { fieldBeingEdited = nil },
            content: {
                YourSpaceRememberedFieldEditor(field: fieldBeingEdited) { field in
                    upsert(field)
                    presentingFieldEditor = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        )
        .confirmationDialog(
            "Delete \(fieldPendingDeletion?.title ?? "this field")?",
            isPresented: Binding(
                get: { fieldPendingDeletion != nil },
                set: { if !$0 { fieldPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let fieldPendingDeletion {
                    rememberedFields.removeAll { $0.id == fieldPendingDeletion.id }
                }
                fieldPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                fieldPendingDeletion = nil
            }
        } message: {
            Text("This removes the field from Your Space. It does not affect anything you already shared.")
        }
    }

    private func rememberedFieldRow(_ field: YourSpaceRememberedField) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: field.category.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 32, height: 32)
                .background(.colorFillMinimal, in: .circle)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(field.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text(field.info)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(3)
            }

            Spacer(minLength: DesignConstants.Spacing.step2x)

            Button {
                onShareField(field)
            } label: {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share \(field.title) to a convo")

            Menu {
                Button("Edit", systemImage: "pencil") {
                    fieldBeingEdited = field
                    presentingFieldEditor = true
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    fieldPendingDeletion = field
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("More actions for \(field.title)")
        }
        .padding(.vertical, DesignConstants.Spacing.stepX)
    }

    private func upsert(_ field: YourSpaceRememberedField) {
        if let index = rememberedFields.firstIndex(where: { $0.id == field.id }) {
            rememberedFields[index] = field
        } else {
            rememberedFields.insert(field, at: 0)
        }
    }

    private func appendToMemory(_ value: String) {
        guard !memory.localizedCaseInsensitiveContains(value) else { return }
        memory = memory.isEmpty ? value : "\(memory)\n\(value)"
    }
}

private struct YourSpaceRememberedFieldEditor: View {
    let field: YourSpaceRememberedField?
    let onSave: (YourSpaceRememberedField) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var category: YourSpaceRememberedFieldCategory
    @State private var title: String
    @State private var info: String
    @FocusState private var focusedField: FocusedField?

    init(
        field: YourSpaceRememberedField?,
        onSave: @escaping (YourSpaceRememberedField) -> Void
    ) {
        self.field = field
        self.onSave = onSave
        _category = State(initialValue: field?.category ?? .other)
        _title = State(initialValue: field?.title ?? "")
        _info = State(initialValue: field?.info ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !info.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Home address, assistant, favorite order…", text: $title)
                        .focused($focusedField, equals: .title)
                        .textInputAutocapitalization(.words)
                        .onChange(of: title) { _, newValue in
                            title = String(newValue.prefix(80))
                        }

                    Picker("Type", selection: $category) {
                        ForEach(YourSpaceRememberedFieldCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                } header: {
                    Text("Field")
                }

                Section {
                    TextField("Add the info you want to keep handy", text: $info, axis: .vertical)
                        .focused($focusedField, equals: .info)
                        .lineLimit(3 ... 8)
                        .onChange(of: info) { _, newValue in
                            info = String(newValue.prefix(2_000))
                        }
                } header: {
                    Text("Info")
                } footer: {
                    Text("Sharing opens a draft in the convo you choose. Nothing sends automatically.")
                }
            }
            .navigationTitle(field == nil ? "Add remembered field" : "Edit remembered field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            focusedField = field == nil ? .title : .info
        }
    }

    private func save() {
        guard canSave else { return }
        let now = Date()
        onSave(YourSpaceRememberedField(
            id: field?.id ?? UUID(),
            category: category,
            title: title,
            info: info,
            createdAt: field?.createdAt ?? now,
            updatedAt: now
        ))
    }

    private enum FocusedField: Hashable {
        case title
        case info
    }
}

struct YourSpaceAddContextSheet: View {
    let onSaved: (YourSpaceStoredFile) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var mode: AddMode?
    @State private var title: String = ""
    @State private var note: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var recorder: VoiceMemoRecorder = .init()
    @State private var presentingFileImporter: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let mode {
                    editor(for: mode)
                } else {
                    optionList
                }
            }
            .navigationTitle(mode?.title ?? "Add context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mode == nil ? "Done" : "Back") {
                        if mode == nil {
                            dismiss()
                        } else {
                            recorder.cancelRecording()
                            mode = nil
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $presentingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .alert("Couldn't add context", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Try again.")
        }
        .onDisappear {
            recorder.cancelRecording()
        }
    }

    private var optionList: some View {
        List {
            Section {
                option(.note, subtitle: "Write something you want to keep")
                option(.photo, subtitle: "Choose an image from your library")
                option(.voice, subtitle: "Record a private voice note")
                Button {
                    presentingFileImporter = true
                } label: {
                    optionLabel(.file, subtitle: "Add a document or any other file")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundSurfaceless)
    }

    private func option(_ mode: AddMode, subtitle: String) -> some View {
        Button {
            self.mode = mode
        } label: {
            optionLabel(mode, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }

    private func optionLabel(_ mode: AddMode, subtitle: String) -> some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: mode.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 40, height: 40)
                .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.small))
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(mode.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.colorTextTertiary)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func editor(for mode: AddMode) -> some View {
        switch mode {
        case .note:
            noteEditor
        case .photo:
            photoEditor
        case .voice:
            voiceEditor
        case .file:
            EmptyView()
        }
    }

    private var noteEditor: some View {
        Form {
            TextField("Title", text: $title)
            TextField("Write anything…", text: $note, axis: .vertical)
                .lineLimit(8 ... 18)
            Button("Save to Your Space") {
                saveNote()
            }
            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
        }
    }

    private var photoEditor: some View {
        VStack(spacing: DesignConstants.Spacing.step5x) {
            ContentUnavailableView(
                "Add a photo",
                systemImage: "photo.on.rectangle.angled",
                description: Text("It stays private in Your Space until you share it.")
            )
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Choose photo", systemImage: "photo.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.colorTextPrimary)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                savePhoto(item)
            }
            if isSaving { ProgressView("Saving photo…") }
        }
        .padding(DesignConstants.Spacing.step6x)
    }

    private var voiceEditor: some View {
        VStack(spacing: DesignConstants.Spacing.step5x) {
            Spacer()
            switch recorder.state {
            case .idle:
                Button {
                    startRecording()
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .frame(width: 88, height: 88)
                        .background(.colorLava, in: .circle)
                }
                .accessibilityLabel("Start recording")
                Text("Tap to record a private voice note")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            case .recording:
                VoiceMemoRecordingView(recorder: recorder)
                    .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            case let .recorded(url, _):
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.colorLava)
                Button("Save voice note") {
                    saveVoice(url)
                }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .tint(.colorTextPrimary)
                Button("Record again", role: .destructive) {
                    recorder.cancelRecording()
                }
            }
            Spacer()
        }
        .padding(DesignConstants.Spacing.step6x)
    }

    private func saveNote() {
        isSaving = true
        do {
            let file = try YourSpaceFileStore.storeText(note, title: title)
            onSaved(file)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func savePhoto(_ item: PhotosPickerItem) {
        isSaving = true
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let filenameExtension = item.supportedContentTypes
                    .compactMap(\.preferredFilenameExtension)
                    .first ?? "jpg"
                let file = try YourSpaceFileStore.store(
                    data: data,
                    named: "Photo \(Int(Date().timeIntervalSince1970)).\(filenameExtension)"
                )
                await MainActor.run {
                    onSaved(file)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }

    private func startRecording() {
        Task {
            guard await VoiceMemoRecorder.ensureRecordPermission() else {
                errorMessage = "Allow microphone access in Settings to record a voice note."
                return
            }
            do {
                try recorder.startRecording()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveVoice(_ url: URL) {
        let outcome = YourSpaceFileStore.importFiles([url])
        guard let name = outcome.importedNames.first,
              let file = YourSpaceFileStore.storedFiles().first(where: { $0.name == name }) else {
            errorMessage = outcome.storageError ?? "The voice note could not be saved."
            return
        }
        onSaved(file)
        dismiss()
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let outcome = YourSpaceFileStore.importFiles(urls)
            guard let name = outcome.importedNames.first,
                  let file = YourSpaceFileStore.storedFiles().first(where: { $0.name == name }) else {
                errorMessage = outcome.storageError ?? "The file could not be added."
                return
            }
            onSaved(file)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private enum AddMode: String, Identifiable {
        case note
        case photo
        case voice
        case file

        var id: String { rawValue }

        var title: String {
            switch self {
            case .note: "New note"
            case .photo: "Photo"
            case .voice: "Voice note"
            case .file: "File"
            }
        }

        var systemImage: String {
            switch self {
            case .note: "note.text.badge.plus"
            case .photo: "photo.badge.plus"
            case .voice: "waveform"
            case .file: "doc.badge.plus"
            }
        }
    }
}

struct YourSpaceShareDestinationSheet: View {
    let item: YourSpaceContextItem
    let conversations: [Conversation]
    let memberNameOverride: (String) -> String?
    let onSelect: (Conversation) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var query: String = ""

    private var filteredConversations: [Conversation] {
        conversations
            .filter {
                query.isEmpty
                    || $0.computedDisplayName(memberNameOverride: memberNameOverride)
                    .localizedCaseInsensitiveContains(query)
            }
            .sorted { ($0.lastMessage?.createdAt ?? $0.createdAt) > ($1.lastMessage?.createdAt ?? $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            List(filteredConversations) { conversation in
                Button {
                    onSelect(conversation)
                } label: {
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        ConversationAvatarView(
                            conversation: conversation,
                            conversationImage: nil,
                            size: 44
                        )
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                            Text(conversation.computedDisplayName(memberNameOverride: memberNameOverride))
                                .font(.body.weight(.medium))
                                .foregroundStyle(.colorTextPrimary)
                            Text("Review in the composer before sending")
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if filteredConversations.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Share \(item.title)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Choose a convo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
