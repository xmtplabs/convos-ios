import ConvosCore
import SwiftUI
import UniformTypeIdentifiers

enum AssistantFilesLinksTab: String, CaseIterable {
    case files = "Files"
    case links = "Links"
}

@MainActor
@Observable
class AssistantFilesLinksViewModel {
    var selectedTab: AssistantFilesLinksTab = .files
    var searchText: String = ""
    var files: [AssistantFile] = []
    var links: [AssistantLink] = []
    var isLoading: Bool = true
    var fileOpenError: String?

    private let repository: AssistantFilesLinksRepository

    init(repository: AssistantFilesLinksRepository) {
        self.repository = repository
    }

    var filteredFiles: [AssistantFile] {
        guard !searchText.isEmpty else { return files }
        let query = searchText.lowercased()
        return files.filter { $0.displayName.lowercased().contains(query) }
    }

    var filteredLinks: [AssistantLink] {
        guard !searchText.isEmpty else { return links }
        let query = searchText.lowercased()
        return links.filter {
            $0.displayTitle.lowercased().contains(query)
            || $0.url.lowercased().contains(query)
        }
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

struct AssistantFilesLinksView: View {
    @State private var viewModel: AssistantFilesLinksViewModel

    init(repository: AssistantFilesLinksRepository) {
        _viewModel = State(initialValue: AssistantFilesLinksViewModel(repository: repository))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewModel.selectedTab) {
                ForEach(AssistantFilesLinksTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step2x)

            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.colorTextSecondary)
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("files-links-search-field")
            }
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(Color.colorFillMinimal)
            )
            .padding(.horizontal, DesignConstants.Spacing.step4x)

            if viewModel.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                switch viewModel.selectedTab {
                case .files:
                    filesTab
                case .links:
                    linksTab
                }
            }
        }
        .navigationTitle("Files & Links")
        .navigationBarTitleDisplayMode(.inline)
        .background(.colorBackgroundRaisedSecondary)
        .task {
            await viewModel.load()
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
    private var filesTab: some View {
        if viewModel.filteredFiles.isEmpty {
            emptyState(text: viewModel.searchText.isEmpty ? "No files yet" : "No files match your search")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredFiles) { file in
                        fileRow(file)
                        Divider()
                            .padding(.leading, 80.0)
                    }
                }
                .padding(.top, DesignConstants.Spacing.step2x)
            }
        }
    }

    @ViewBuilder
    private var linksTab: some View {
        if viewModel.filteredLinks.isEmpty {
            emptyState(text: viewModel.searchText.isEmpty ? "No links yet" : "No links match your search")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredLinks) { link in
                        linkRow(link)
                        Divider()
                            .padding(.leading, 80.0)
                    }
                }
                .padding(.top, DesignConstants.Spacing.step2x)
            }
        }
    }

    private func fileRow(_ file: AssistantFile) -> some View {
        let action = {
            Task {
                do {
                    let url = try await FileAttachmentPreviewLoader.loadPreviewURL(
                        key: file.attachmentKey,
                        filename: file.filename
                    )
                    guard let presenter = UIApplication.shared.topMostViewController() else { return }
                    FileAttachmentQuickLookCoordinator.shared.present(fileURL: url, from: presenter)
                } catch {
                    Log.error("Failed to open assistant file: \(error)")
                    viewModel.fileOpenError = "This file is no longer available on this device."
                }
            }
        }
        return Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                fileThumbnail(file)
                    .frame(width: 56.0, height: 56.0)
                    .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small))

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(file.displayName)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)

                    Text(fileSubtitle(file))
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileSubtitle(_ file: AssistantFile) -> String {
        var parts: [String] = []
        if let mimeType = file.mimeType,
           let utType = UTType(mimeType: mimeType),
           let ext = utType.preferredFilenameExtension {
            parts.append(ext.uppercased())
        } else if let ext = (file.filename as NSString?)?.pathExtension, !ext.isEmpty {
            parts.append(ext.uppercased())
        }
        parts.append(file.formattedDate)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func fileThumbnail(_ file: AssistantFile) -> some View {
        if let base64 = file.thumbnailDataBase64,
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

    private func linkRow(_ link: AssistantLink) -> some View {
        let action = {
            if let url = link.resolvedURL {
                UIApplication.shared.open(url)
            }
        }
        return Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                linkThumbnail(link)
                    .frame(width: 56.0, height: 56.0)
                    .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small))

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(link.displayTitle)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)

                    Text(link.displayHost)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "safari")
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .contentShape(Rectangle())
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

    private func emptyState(text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
            Spacer()
        }
    }
}
