import ConvosCore
import SwiftUI
import UniformTypeIdentifiers

enum StuffFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case links = "Links"
    case files = "Files"

    var id: String { rawValue }
}

enum StuffItem: Identifiable {
    case file(AssistantFile)
    case link(AssistantLink)

    var id: String {
        switch self {
        case .file(let file): return "file-\(file.id)"
        case .link(let link): return "link-\(link.id)"
        }
    }

    var date: Date {
        switch self {
        case .file(let file): return file.date
        case .link(let link): return link.date
        }
    }
}

@MainActor
@Observable
class AssistantFilesLinksViewModel {
    var filter: StuffFilter = .all
    var searchText: String = ""
    var files: [AssistantFile] = []
    var links: [AssistantLink] = []
    var isLoading: Bool = true
    var fileOpenError: String?

    private let repository: AssistantFilesLinksRepository

    init(repository: AssistantFilesLinksRepository) {
        self.repository = repository
    }

    var hasAnyItems: Bool {
        !files.isEmpty || !links.isEmpty
    }

    var isFiltering: Bool {
        filter != .all || !searchText.isEmpty
    }

    var filteredItems: [StuffItem] {
        let query = searchText.lowercased()

        var items: [StuffItem] = []

        if filter == .all || filter == .files {
            for file in files where matches(file: file, query: query) {
                items.append(.file(file))
            }
        }

        if filter == .all || filter == .links {
            for link in links where matches(link: link, query: query) {
                items.append(.link(link))
            }
        }

        items.sort { $0.date > $1.date }
        return items
    }

    func clearFilters() {
        filter = .all
        searchText = ""
    }

    private func matches(file: AssistantFile, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return file.displayName.lowercased().contains(query)
    }

    private func matches(link: AssistantLink, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return link.displayTitle.lowercased().contains(query)
            || link.url.lowercased().contains(query)
    }

    func load() async {
        isLoading = true
        do {
            async let fetchedFiles = repository.fetchFiles()
            async let fetchedLinks = repository.fetchLinks()
            files = try await fetchedFiles
            links = try await fetchedLinks
        } catch {
            Log.error("Failed to load assistant files and links: \(error.localizedDescription)")
        }
        isLoading = false
    }
}

struct AttachmentPreviewPresentation: Identifiable {
    let id: String
    let attachment: HydratedAttachment
    let fileURL: URL
    let sender: ConversationMember?
    let sentAt: Date
}

struct AssistantFilesLinksView: View {
    @State private var viewModel: AssistantFilesLinksViewModel
    @State private var presentingPreview: AttachmentPreviewPresentation?
    private let members: [ConversationMember]

    init(repository: AssistantFilesLinksRepository, members: [ConversationMember]) {
        _viewModel = State(initialValue: AssistantFilesLinksViewModel(repository: repository))
        self.members = members
    }

    private func member(forInboxId inboxId: String) -> ConversationMember? {
        members.first { $0.profile.inboxId == inboxId }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("Stuff")
            .toolbarTitleDisplayMode(.large)
            .safeAreaBar(edge: .bottom) {
                StuffSearchBar(
                    searchText: $viewModel.searchText,
                    filter: $viewModel.filter
                )
            }
            .task {
                await viewModel.load()
            }
            .sheet(item: $presentingPreview) { preview in
                AttachmentPreviewSheet(
                    attachment: preview.attachment,
                    fileURL: preview.fileURL,
                    sender: preview.sender,
                    sentAt: preview.sentAt
                )
                .presentationDetents([.large])
            }
            .alert("File Unavailable", isPresented: Binding(
                get: { viewModel.fileOpenError != nil },
                set: { if !$0 { viewModel.fileOpenError = nil } }
            )) {
                Button("OK", role: .cancel) {
                    viewModel.fileOpenError = nil
                }
            } message: {
                Text(viewModel.fileOpenError ?? "This file is no longer available on this device.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            emptyState
        } else {
            itemList
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.filteredItems) { item in
                    row(for: item)
                    Divider()
                        .padding(.leading, Constant.dividerInset)
                }
            }
            .padding(.top, DesignConstants.Spacing.step2x)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isFiltering {
            VStack {
                Spacer()
                FilteredEmptyStateView(message: filteredEmptyMessage) {
                    viewModel.clearFilters()
                }
                .padding(.horizontal, DesignConstants.Spacing.step6x)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Spacer()
                Text("Nothing here yet")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filteredEmptyMessage: String {
        if !viewModel.searchText.isEmpty { return "Nothing matches your search" }
        switch viewModel.filter {
        case .all: return "Nothing matches"
        case .files: return "No files"
        case .links: return "No links"
        }
    }

    @ViewBuilder
    private func row(for item: StuffItem) -> some View {
        switch item {
        case .file(let file):
            fileRow(file)
        case .link(let link):
            linkRow(link)
        }
    }

    private func fileRow(_ file: AssistantFile) -> some View {
        FileRow(
            file: file,
            subtitle: relativeDate(for: file.date),
            onTap: { openFile(file) }
        )
    }

    private func openFile(_ file: AssistantFile) {
        Task {
            do {
                let url = try await FileAttachmentPreviewLoader.loadPreviewURL(
                    key: file.attachmentKey,
                    filename: file.filename
                )
                await MainActor.run {
                    let hydrated = HydratedAttachment(
                        key: file.attachmentKey,
                        mimeType: file.mimeType,
                        thumbnailDataBase64: file.thumbnailDataBase64,
                        filename: file.filename
                    )
                    presentingPreview = AttachmentPreviewPresentation(
                        id: file.id,
                        attachment: hydrated,
                        fileURL: url,
                        sender: member(forInboxId: file.senderInboxId),
                        sentAt: file.date
                    )
                }
            } catch {
                Log.error("Failed to open assistant file: \(error)")
                await MainActor.run {
                    viewModel.fileOpenError = "This file is no longer available on this device."
                }
            }
        }
    }

    private func linkRow(_ link: AssistantLink) -> some View {
        let action = {
            if let url = link.resolvedURL {
                UIApplication.shared.open(url)
            }
        }
        return Button(action: action) {
            StuffRowContent(
                thumbnail: { linkThumbnail(link) },
                title: link.displayTitle,
                subtitle: relativeDate(for: link.date),
                trailingSymbol: "globe"
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linkThumbnail(_ link: AssistantLink) -> some View {
        if let imageURL = link.imageURL, let url = URL(string: imageURL) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                linkPlaceholder
            }
        } else {
            linkPlaceholder
        }
    }

    private var linkPlaceholder: some View {
        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
            .fill(Color.colorFillMinimal)
            .overlay {
                Image(systemName: "link")
                    .foregroundStyle(.colorTextSecondary)
            }
    }

    private func relativeDate(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, (1..<7).contains(days) {
            return "\(days)d ago"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
    }

    private enum Constant {
        static let dividerInset: CGFloat = 80.0
    }
}

private struct FileRow: View {
    let file: AssistantFile
    let subtitle: String
    let onTap: () -> Void

    @State private var renderedHTMLPreview: UIImage?
    @State private var resolvedHTMLTitle: String?
    @State private var renderedFilePreview: UIImage?

    var body: some View {
        Button(action: onTap) {
            StuffRowContent(
                thumbnail: { thumbnail },
                title: displayTitle,
                subtitle: subtitle,
                trailingSymbol: "doc"
            )
        }
        .buttonStyle(.plain)
        .task(id: file.attachmentKey) {
            await loadHTMLMetadataIfNeeded()
        }
    }

    private var displayTitle: String {
        if let resolvedHTMLTitle, !resolvedHTMLTitle.isEmpty {
            return resolvedHTMLTitle
        }
        return file.displayName
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let renderedHTMLPreview {
            Image(uiImage: renderedHTMLPreview)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let renderedFilePreview {
            Image(uiImage: renderedFilePreview)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let base64 = file.thumbnailDataBase64,
                  let data = Data(base64Encoded: base64),
                  let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
                .fill(Color.colorFillMinimal)
                .overlay {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.colorTextSecondary)
                }
        }
    }

    private var isHTML: Bool {
        if let filename = file.filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            if ["html", "htm"].contains(ext) { return true }
        }
        return file.mimeType?.lowercased() == "text/html"
    }

    private func loadHTMLMetadataIfNeeded() async {
        if isHTML {
            renderedHTMLPreview = HTMLThumbnailRenderer.shared.cachedThumbnail(for: file.attachmentKey)
            resolvedHTMLTitle = HTMLPageMetadata.shared.cachedTitle(for: file.attachmentKey)
        } else if let cached = FileThumbnailRenderer.shared.cachedThumbnail(for: file.attachmentKey),
                  cached.isContentThumbnail {
            renderedFilePreview = cached.image
        }

        guard renderedHTMLPreview == nil
            || resolvedHTMLTitle == nil
            || (!isHTML && renderedFilePreview == nil)
        else { return }

        do {
            let url = try await FileAttachmentPreviewLoader.loadPreviewURL(
                key: file.attachmentKey,
                filename: file.filename
            )

            if isHTML {
                if renderedHTMLPreview == nil {
                    renderedHTMLPreview = await HTMLThumbnailRenderer.shared.thumbnail(
                        for: file.attachmentKey,
                        fileURL: url
                    )
                }
                if resolvedHTMLTitle == nil {
                    resolvedHTMLTitle = await HTMLPageMetadata.shared.title(
                        for: file.attachmentKey,
                        fileURL: url
                    )
                }
            } else if renderedFilePreview == nil {
                let result = await FileThumbnailRenderer.shared.thumbnail(
                    for: file.attachmentKey,
                    fileURL: url
                )
                if let result, result.isContentThumbnail {
                    renderedFilePreview = result.image
                }
            }
        } catch {
            Log.error("Failed to load Stuff list file metadata: \(error)")
        }
    }
}

private struct StuffRowContent<Thumbnail: View>: View {
    @ViewBuilder let thumbnail: () -> Thumbnail
    let title: String
    let subtitle: String
    let trailingSymbol: String

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            thumbnail()
                .frame(width: 56.0, height: 56.0)
                .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small))

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: trailingSymbol)
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .contentShape(Rectangle())
    }
}

private struct StuffSearchBar: View {
    @Binding var searchText: String
    @Binding var filter: StuffFilter

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.colorTextSecondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("stuff-search-field")
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .glassEffect(.regular.interactive(), in: .capsule)

                filterMenu
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(StuffFilter.allCases) { option in
                let action = { filter = option }
                Button(action: action) {
                    if option == filter {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 48.0, height: 48.0)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(filter.rawValue)
        .accessibilityIdentifier("stuff-filter-button")
    }
}
