import ConvosCore
import Foundation
import UniformTypeIdentifiers

struct YourSpaceUpdate: Identifiable, Equatable {
    let conversation: Conversation
    let conversationTitle: String
    let personName: String?
    let detail: String
    let date: Date
    let needsAttention: Bool

    var id: String { conversation.id }

    var shareText: String {
        if let personName {
            return "\(personName) in \(conversationTitle): \(detail)"
        }
        return "\(conversationTitle): \(detail)"
    }
}

struct YourSpaceBriefing: Equatable {
    let headline: String
    let attentionUpdates: [YourSpaceUpdate]
    let recentUpdates: [YourSpaceUpdate]
    let sourceCount: Int
    let peopleCount: Int

    var attentionCount: Int { attentionUpdates.count }
}

struct YourSpaceStoredFile: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let byteCount: Int
    let addedAt: Date

    var id: String { url.path }
}

enum YourSpaceContextKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case useful
    case photo
    case video
    case link
    case file
    case voice
    case note
    case address
    case phone
    case email
    case detail

    var id: String { rawValue }

    static let browserFilters: [YourSpaceContextKind] = [
        .all,
        .useful,
        .address,
        .phone,
        .email,
        .photo,
        .link,
        .file,
        .detail,
    ]

    var isUsefulDetailFilter: Bool {
        [.useful, .address, .phone, .email].contains(self)
    }

    var title: String {
        switch self {
        case .all: "All"
        case .useful: "Useful details"
        case .photo: "Photos"
        case .video: "Videos"
        case .link: "Links"
        case .file: "Files"
        case .voice: "Voice"
        case .note: "Notes"
        case .address: "Addresses"
        case .phone: "Phone numbers"
        case .email: "Emails"
        case .detail: "Remembered"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .useful: "sparkles.rectangle.stack.fill"
        case .photo: "photo.fill"
        case .video: "play.rectangle.fill"
        case .link: "link"
        case .file: "doc.fill"
        case .voice: "waveform"
        case .note: "note.text"
        case .address: "map.fill"
        case .phone: "phone.fill"
        case .email: "envelope.fill"
        case .detail: "text.badge.checkmark"
        }
    }
}

enum YourSpaceRememberedFieldCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case address
    case phone
    case email
    case website
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .address: "Address"
        case .phone: "Phone number"
        case .email: "Email"
        case .website: "Website"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .address: "map.fill"
        case .phone: "phone.fill"
        case .email: "envelope.fill"
        case .website: "globe"
        case .other: "text.badge.checkmark"
        }
    }

    var contextKind: YourSpaceContextKind {
        switch self {
        case .address: .address
        case .phone: .phone
        case .email: .email
        case .website: .link
        case .other: .detail
        }
    }
}

struct YourSpaceRememberedField: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let category: YourSpaceRememberedFieldCategory
    let title: String
    let info: String
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        category: YourSpaceRememberedFieldCategory,
        title: String,
        info: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.info = info.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var shareText: String { "\(title): \(info)" }
}

enum YourSpaceRememberedFieldStore {
    private static let key: String = "your-space-card-remembered-fields-v1"
    private static let maximumFieldCount: Int = 100

    static func fields(defaults: UserDefaults = .standard) -> [YourSpaceRememberedField] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([YourSpaceRememberedField].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(maximumFieldCount))
    }

    static func save(_ fields: [YourSpaceRememberedField], defaults: UserDefaults = .standard) {
        let boundedFields = Array(fields.prefix(maximumFieldCount))
        guard let data = try? JSONEncoder().encode(boundedFields) else { return }
        defaults.set(data, forKey: key)
    }
}

enum YourSpaceContextSource: Hashable, Sendable {
    case local(YourSpaceStoredFile)
    case conversation(ContextLibraryItem)
    case rememberedField(YourSpaceRememberedField)
}

struct YourSpaceContextItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: YourSpaceContextKind
    let title: String
    let detail: String?
    let date: Date
    let conversationId: String?
    let senderInboxId: String?
    let isMine: Bool
    let source: YourSpaceContextSource

    init(local file: YourSpaceStoredFile) {
        id = "local-\(file.id)"
        kind = Self.kind(filename: file.name)
        title = file.name
        detail = nil
        date = file.addedAt
        conversationId = nil
        senderInboxId = nil
        isMine = true
        source = .local(file)
    }

    init(conversation item: ContextLibraryItem) {
        id = item.id
        kind = YourSpaceContextKind(rawValue: item.kind.rawValue) ?? .file
        title = item.title
        detail = item.messageText
        date = item.date
        conversationId = item.conversationId
        senderInboxId = item.senderInboxId
        isMine = item.isMine
        source = .conversation(item)
    }

    var isAutomaticallyIndexedUsefulDetail: Bool {
        guard case .conversation = source else { return false }
        return [.address, .phone, .email].contains(kind)
    }

    func matchesBrowserFilter(_ filter: YourSpaceContextKind) -> Bool {
        switch filter {
        case .all:
            true
        case .useful:
            isAutomaticallyIndexedUsefulDetail
        case .address, .phone, .email:
            isAutomaticallyIndexedUsefulDetail && kind == filter
        case .file:
            [.file, .video, .voice, .note].contains(kind)
        default:
            kind == filter
        }
    }

    init(rememberedField field: YourSpaceRememberedField) {
        id = "remembered-\(field.id.uuidString)"
        kind = field.category.contextKind
        title = field.title
        detail = field.info
        date = field.updatedAt
        conversationId = nil
        senderInboxId = nil
        isMine = true
        source = .rememberedField(field)
    }

    private static func kind(filename: String) -> YourSpaceContextKind {
        let pathExtension = (filename as NSString).pathExtension
        if pathExtension.caseInsensitiveCompare("url") == .orderedSame { return .link }
        guard let type = UTType(filenameExtension: pathExtension) else { return .file }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .voice }
        if type.conforms(to: .plainText) { return .note }
        return .file
    }
}

struct YourSpaceFileImportOutcome: Equatable, Sendable {
    let importedNames: [String]
    let skippedNames: [String]
    let storageError: String?
}

struct YourSpaceFileImportNotice: Identifiable {
    let id: UUID = UUID()
    let title: String
    let message: String

    init(outcome: YourSpaceFileImportOutcome) {
        if outcome.importedNames.isEmpty {
            title = "Couldn't add files"
            if let storageError = outcome.storageError {
                message = storageError
            } else if outcome.skippedNames.isEmpty {
                message = "No files were selected."
            } else {
                message = "The selected files could not be added. Files must be regular documents no larger than 20 MB."
            }
            return
        }

        title = outcome.importedNames.count == 1 ? "File added" : "Files added"
        let storedMessage = outcome.importedNames.count == 1
            ? "The file is stored privately in Your Space on this device."
            : "\(outcome.importedNames.count) files are stored privately in Your Space on this device."
        if outcome.skippedNames.isEmpty {
            message = storedMessage
        } else {
            let skippedMessage = outcome.skippedNames.count == 1
                ? "1 file was skipped because it was unsupported or larger than 20 MB."
                : "\(outcome.skippedNames.count) files were skipped because they were unsupported or larger than 20 MB."
            message = "\(storedMessage) \(skippedMessage)"
        }
    }

    init(error: Error) {
        title = "Couldn't open files"
        message = error.localizedDescription
    }

    init(deletionError: Error) {
        title = "Couldn't delete file"
        message = deletionError.localizedDescription
    }
}

enum YourSpaceFileStore {
    private static let directoryName: String = "Your Space Files"
    private static let maxFileSize: Int = 20 * 1024 * 1024
    private static let maxFilesPerImport: Int = 20

    static func importFiles(_ urls: [URL]) -> YourSpaceFileImportOutcome {
        let fileManager = FileManager.default
        let directory: URL

        do {
            directory = try storageDirectory(fileManager: fileManager)
        } catch {
            return YourSpaceFileImportOutcome(
                importedNames: [],
                skippedNames: urls.map(\.lastPathComponent),
                storageError: error.localizedDescription
            )
        }

        var importedNames: [String] = []
        var skippedNames: [String] = []

        for url in urls.prefix(maxFilesPerImport) {
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let byteCount = values.fileSize,
                      byteCount <= maxFileSize else {
                    skippedNames.append(url.lastPathComponent)
                    continue
                }

                let destination = availableDestination(
                    for: url.lastPathComponent,
                    in: directory,
                    fileManager: fileManager
                )
                try fileManager.copyItem(at: url, to: destination)
                importedNames.append(destination.lastPathComponent)
            } catch {
                skippedNames.append(url.lastPathComponent)
            }
        }

        if urls.count > maxFilesPerImport {
            skippedNames.append(contentsOf: urls.dropFirst(maxFilesPerImport).map(\.lastPathComponent))
        }

        return YourSpaceFileImportOutcome(
            importedNames: importedNames,
            skippedNames: skippedNames,
            storageError: nil
        )
    }

    static func store(data: Data, named proposedName: String) throws -> YourSpaceStoredFile {
        guard data.count <= maxFileSize else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let fileManager = FileManager.default
        let directory = try storageDirectory(fileManager: fileManager)
        let destination = availableDestination(
            for: sanitizedName(proposedName),
            in: directory,
            fileManager: fileManager
        )
        try data.write(to: destination, options: .atomic)
        return storedFile(at: destination) ?? YourSpaceStoredFile(
            url: destination,
            name: destination.lastPathComponent,
            byteCount: data.count,
            addedAt: Date()
        )
    }

    static func storeText(_ text: String, title: String) throws -> YourSpaceStoredFile {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedTitle.isEmpty ? "Note" : trimmedTitle
        return try store(data: Data(text.utf8), named: "\(baseName).txt")
    }

    static func storeLink(_ url: URL) throws -> YourSpaceStoredFile {
        let title = url.host(percentEncoded: false) ?? "Codex link"
        return try store(data: Data(url.absoluteString.utf8), named: "\(title).url")
    }

    static func temporaryCopy(of file: YourSpaceStoredFile) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Your Space Share", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(file.name, isDirectory: false)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: file.url, to: destination)
        return destination
    }

    static func storedFiles() -> [YourSpaceStoredFile] {
        let fileManager = FileManager.default
        guard let directory = try? storageDirectory(fileManager: fileManager),
              let urls = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls.compactMap(storedFile(at:))
        .sorted { $0.addedAt > $1.addedAt }
    }

    static func deleteFile(at url: URL) throws {
        let fileManager = FileManager.default
        let directory = try storageDirectory(fileManager: fileManager).standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.removeItem(at: candidate)
    }

    private static func storageDirectory(fileManager: FileManager) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(resourceValues)
        return directory
    }

    private static func availableDestination(
        for proposedName: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let fallbackName = proposedName.isEmpty ? "Untitled" : proposedName
        let originalURL = URL(fileURLWithPath: fallbackName)
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension
        var destination = directory.appendingPathComponent(fallbackName, isDirectory: false)
        var suffix = 2

        while fileManager.fileExists(atPath: destination.path) {
            let candidateName = pathExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(pathExtension)"
            destination = directory.appendingPathComponent(candidateName, isDirectory: false)
            suffix += 1
        }
        return destination
    }

    private static func storedFile(at url: URL) -> YourSpaceStoredFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        return YourSpaceStoredFile(
            url: url,
            name: url.lastPathComponent,
            byteCount: values.fileSize ?? 0,
            addedAt: values.creationDate ?? .distantPast
        )
    }

    private static func sanitizedName(_ proposedName: String) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Untitled" : trimmed
        return fallback
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

enum YourSpaceBriefingBuilder {
    static func make(
        conversations: [Conversation],
        memberNameOverride: (String) -> String? = { _ in nil }
    ) -> YourSpaceBriefing {
        let visibleConversations = conversations
            .sorted { activityDate(for: $0) > activityDate(for: $1) }
        let updates = visibleConversations.compactMap {
            makeUpdate(for: $0, memberNameOverride: memberNameOverride)
        }
        let attention = updates.filter(\.needsAttention)

        return YourSpaceBriefing(
            headline: headline(
                sourceCount: visibleConversations.count,
                attentionUpdates: attention
            ),
            attentionUpdates: attention,
            recentUpdates: Array(updates.prefix(8)),
            sourceCount: visibleConversations.count,
            peopleCount: peopleCount(in: visibleConversations)
        )
    }

    private static func makeUpdate(
        for conversation: Conversation,
        memberNameOverride: (String) -> String?
    ) -> YourSpaceUpdate? {
        let title = conversation.computedDisplayName(memberNameOverride: memberNameOverride)

        if conversation.isPendingInvite {
            return YourSpaceUpdate(
                conversation: conversation,
                conversationTitle: title,
                personName: nil,
                detail: "Your invite is still being verified.",
                date: conversation.createdAt,
                needsAttention: true
            )
        }

        guard let preview = latestPreview(for: conversation) else { return nil }

        return YourSpaceUpdate(
            conversation: conversation,
            conversationTitle: title,
            // MessagePreview does not currently expose sender metadata. Never
            // infer identity from message text; richer person attribution can
            // be added once the repository supplies a verified sender.
            personName: nil,
            detail: previewDetail(preview.text),
            date: preview.createdAt,
            needsAttention: conversation.isUnread || conversation.agentDm?.isUnread == true
        )
    }

    private static func latestPreview(for conversation: Conversation) -> MessagePreview? {
        switch (conversation.lastMessage, conversation.agentDm?.lastMessage) {
        case let (group?, agent?):
            return group.createdAt >= agent.createdAt ? group : agent
        case let (group?, nil):
            return group
        case let (nil, agent?):
            return agent
        case (nil, nil):
            return nil
        }
    }

    private static func activityDate(for conversation: Conversation) -> Date {
        latestPreview(for: conversation)?.createdAt ?? conversation.createdAt
    }

    private static func previewDetail(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Shared a new update."
        }
        return clipped(trimmed)
    }

    private static func clipped(_ value: String) -> String {
        let limit = 180
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func headline(sourceCount: Int, attentionUpdates: [YourSpaceUpdate]) -> String {
        guard sourceCount > 0 else {
            return "Your private space is ready. Add a convo or connect an agent, and it will start keeping up with you."
        }

        guard let first = attentionUpdates.first else {
            let noun = sourceCount == 1 ? "convo" : "convos"
            return "You’re caught up. Your agents are quietly keeping up with \(sourceCount) \(noun)."
        }

        if attentionUpdates.count == 1 {
            return "\(first.conversationTitle) has something new for you."
        }

        let updateWord = attentionUpdates.count == 1 ? "update" : "updates"
        return "You have \(attentionUpdates.count) \(updateWord) to catch up on. Start with \(first.conversationTitle)."
    }

    private static func peopleCount(in conversations: [Conversation]) -> Int {
        Set(conversations.flatMap(\.membersWithoutCurrent).map(\.profile.inboxId)).count
    }
}
