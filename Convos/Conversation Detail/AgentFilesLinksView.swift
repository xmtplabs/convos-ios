import Combine
import ConvosCore
import ConvosMetrics
import SwiftUI
import UniformTypeIdentifiers

enum StuffFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case links = "Links"
    case files = "Files"

    var id: String { rawValue }
}

enum StuffItem: Identifiable {
    case file(AgentFile)
    case link(AgentLink)

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
class AgentFilesLinksViewModel {
    var filter: StuffFilter = .all
    var searchText: String = ""
    var files: [AgentFile] = []
    var links: [AgentLink] = []
    var isLoading: Bool = true
    var fileOpenError: String?

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    /// Rebind to a repository. Cancels any existing subscriptions, resets the
    /// view-facing state, and resubscribes. Safe to call repeatedly — the view
    /// drives this from `.onChange(of: conversationId)` so the same view model
    /// instance follows the active conversation.
    func observe(_ repository: AgentFilesLinksRepository) {
        cancellables.removeAll()
        files = []
        links = []
        filter = .all
        searchText = ""
        fileOpenError = nil
        isLoading = true

        // Both publishers wrap GRDB ValueObservation with replaceError(with: [])
        // so they cannot fail and each emits an initial value (possibly empty).
        // First emission from either is enough to leave the loading state — the
        // empty-state UI handles the "files arrived, links pending" race.
        repository.filesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newFiles in
                self?.files = newFiles
                self?.isLoading = false
            }
            .store(in: &cancellables)

        repository.linksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLinks in
                self?.links = newLinks
                self?.isLoading = false
            }
            .store(in: &cancellables)
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

    private func matches(file: AgentFile, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if file.displayName.lowercased().contains(query) {
            return true
        }
        if let htmlTitle = HTMLPageMetadata.shared.cachedTitle(for: file.attachmentKey),
           htmlTitle.lowercased().contains(query) {
            return true
        }
        return false
    }

    private func matches(link: AgentLink, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return link.displayTitle.lowercased().contains(query)
            || link.url.lowercased().contains(query)
    }
}

struct AttachmentPreviewPresentation: Identifiable {
    let id: String
    let attachment: HydratedAttachment
    let fileURL: URL
    let sender: ConversationMember?
    let sentAt: Date
}

struct AgentFilesLinksView: View {
    let conversationId: String
    let repository: AgentFilesLinksRepository
    let members: [ConversationMember]
    var usesInlineHeader: Bool = false
    var profileSheetContent: ((ConversationMember) -> AnyView)?
    var focusBinding: FocusState<MessagesViewInputFocus?>.Binding?

    @State private var viewModel: AgentFilesLinksViewModel = .init()
    @State private var presentingPreview: AttachmentPreviewPresentation?
    @State private var navState: AgentFilesLinksNavigatorImpl = .init()
    @State private var navigator: AgentFilesLinksCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = AgentFilesLinksCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private func handleAttachmentPreviewChanged(from oldValue: AttachmentPreviewPresentation?, to newValue: AttachmentPreviewPresentation?) {
        guard oldValue == nil, let newValue else { return }
        navigator?.present(
            attachmentPreview: AttachmentPreviewNavigatorArgs(
                conversationId: conversationId,
                senderInboxId: newValue.sender?.profile.inboxId
            )
        )
    }

    private func member(forInboxId inboxId: String) -> ConversationMember? {
        members.first { $0.profile.inboxId == inboxId }
    }

    var body: some View {
        bodyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .applyTitle(usesInlineHeader: usesInlineHeader)
            .safeAreaBar(edge: .bottom) {
                StuffSearchBar(
                    searchText: $viewModel.searchText,
                    filter: $viewModel.filter,
                    focusBinding: focusBinding
                )
            }
            .sheet(item: $presentingPreview) { preview in
                AttachmentPreviewSheet(
                    attachment: preview.attachment,
                    fileURL: preview.fileURL,
                    sender: preview.sender,
                    sentAt: preview.sentAt,
                    profileSheetContent: profileSheetContent
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
            // `initial: true` runs the binding once on first appear and then again
            // whenever the active conversation changes — the same view model
            // instance follows the selection instead of being torn down via `.id`.
            .onChange(of: conversationId, initial: true) {
                viewModel.observe(repository)
                presentingPreview = nil
            }
            .onAppear {
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
            }
            .onChange(of: presentingPreview?.id) { oldId, newId in
                guard oldId == nil, newId != nil else { return }
                handleAttachmentPreviewChanged(from: nil, to: presentingPreview)
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if usesInlineHeader {
            VStack(alignment: .leading, spacing: 0) {
                Text("Stuff")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.colorTextPrimary)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .padding(.top, DesignConstants.Spacing.step2x)
                    .padding(.bottom, DesignConstants.Spacing.step3x)
                content
            }
        } else {
            content
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
                }
            }
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

    private func fileRow(_ file: AgentFile) -> some View {
        FileRow(
            file: file,
            subtitle: relativeDate(for: file.date),
            onTap: { openFile(file) }
        )
    }

    private func openFile(_ file: AgentFile) {
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
                Log.error("Failed to open agent file: \(error)")
                await MainActor.run {
                    viewModel.fileOpenError = "This file is no longer available on this device."
                }
            }
        }
    }

    private func linkRow(_ link: AgentLink) -> some View {
        let action = {
            if let url = link.resolvedURL {
                InAppBrowser.open(url)
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
    private func linkThumbnail(_ link: AgentLink) -> some View {
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
        Image(systemName: "link")
            .foregroundStyle(.colorTextSecondary)
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
}

private struct FileRow: View {
    let file: AgentFile
    let subtitle: String
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var renderedHTMLPreview: UIImage?
    @State private var resolvedHTMLTitle: String?
    @State private var renderedFilePreview: UIImage?

    var body: some View {
        Button(action: onTap) {
            StuffRowContent(
                thumbnail: { thumbnail },
                title: displayTitle,
                subtitle: subtitle,
                trailingSymbol: isHTML ? "globe" : "doc"
            )
        }
        .buttonStyle(.plain)
        .task(id: AttachmentColorSchemeKey(key: file.attachmentKey, scheme: colorScheme)) {
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
                .aspectRatio(contentMode: .fit)
        } else if let renderedFilePreview {
            Image(uiImage: renderedFilePreview)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let base64 = file.thumbnailDataBase64,
                  let data = Data(base64Encoded: base64),
                  let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "doc.fill")
                .foregroundStyle(.colorTextSecondary)
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
        let appearance = colorScheme.uiUserInterfaceStyle
        if isHTML {
            renderedHTMLPreview = HTMLThumbnailRenderer.shared.cachedThumbnail(
                for: file.attachmentKey,
                appearance: appearance
            )
            resolvedHTMLTitle = HTMLPageMetadata.shared.cachedTitle(for: file.attachmentKey)
        } else if let cached = FileThumbnailRenderer.shared.cachedThumbnail(for: file.attachmentKey),
                  cached.isContentThumbnail {
            renderedFilePreview = cached.image
        }

        let needsLoad: Bool = isHTML
            ? (renderedHTMLPreview == nil || resolvedHTMLTitle == nil)
            : (renderedFilePreview == nil)
        guard needsLoad else { return }

        do {
            let url = try await FileAttachmentPreviewLoader.loadPreviewURL(
                key: file.attachmentKey,
                filename: file.filename
            )

            if isHTML {
                if renderedHTMLPreview == nil {
                    renderedHTMLPreview = await HTMLThumbnailRenderer.shared.thumbnail(
                        for: file.attachmentKey,
                        fileURL: url,
                        appearance: appearance
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
                .frame(width: StuffRowMetrics.thumbnailSize, height: StuffRowMetrics.thumbnailSize)
                .background(Color.colorFillMinimal)
                .clipShape(RoundedRectangle(cornerRadius: StuffRowMetrics.thumbnailCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: StuffRowMetrics.thumbnailCornerRadius)
                        .strokeBorder(Color.colorBorderEdge, lineWidth: 1.0)
                )

            VStack(alignment: .leading, spacing: StuffRowMetrics.titleSubtitleSpacing) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignConstants.Spacing.step3x)

            Image(systemName: trailingSymbol)
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .contentShape(Rectangle())
    }
}

private enum StuffRowMetrics {
    static let thumbnailSize: CGFloat = 47.0
    static let thumbnailCornerRadius: CGFloat = 16.0
    static let titleSubtitleSpacing: CGFloat = 3.0
}

private extension View {
    @ViewBuilder
    func applyTitle(usesInlineHeader: Bool) -> some View {
        if usesInlineHeader {
            self
        } else {
            self
                .navigationTitle("Stuff")
                .toolbarTitleDisplayMode(.large)
        }
    }
}

private struct StuffSearchBar: View {
    @Binding var searchText: String
    @Binding var filter: StuffFilter
    var focusBinding: FocusState<MessagesViewInputFocus?>.Binding?

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.colorTextSecondary)
                    searchTextField
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

    @ViewBuilder
    private var searchTextField: some View {
        let textField = TextField("Search", text: $searchText)
            .textFieldStyle(.plain)
            .accessibilityIdentifier("stuff-search-field")
        if let focusBinding {
            textField.focused(focusBinding, equals: .stuffSearchBar)
        } else {
            textField
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
