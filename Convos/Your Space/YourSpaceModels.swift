import ConvosCore
import Foundation

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

struct YourSpaceStoredFile: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let byteCount: Int
    let addedAt: Date

    var id: String { url.path }
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

        return urls.compactMap { url in
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
            return "Your private space is ready. Start a convo and the context will grow with you."
        }

        guard let first = attentionUpdates.first else {
            let noun = sourceCount == 1 ? "convo" : "convos"
            return "Nothing needs you right now. Your Space is quietly keeping up with \(sourceCount) \(noun)."
        }

        guard let second = attentionUpdates.dropFirst().first else {
            return headlineClause(for: first)
        }

        let remaining = attentionUpdates.count - 2
        let ending = remaining > 0
            ? " \(remaining) more \(remaining == 1 ? "convo has" : "convos have") new context."
            : ""
        return headlineClause(for: first) + " "
            + headlineClause(for: second)
            + ending
    }

    private static func headlineClause(for update: YourSpaceUpdate) -> String {
        if let personName = update.personName {
            return "\(personName) shared something new in \(update.conversationTitle)."
        }
        return "\(update.conversationTitle) has new context."
    }

    private static func peopleCount(in conversations: [Conversation]) -> Int {
        Set(conversations.flatMap(\.membersWithoutCurrent).map(\.profile.inboxId)).count
    }
}
