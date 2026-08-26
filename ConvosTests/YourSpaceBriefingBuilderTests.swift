@testable import Convos
import ConvosCore
import UIKit
import XCTest

final class YourSpaceBriefingBuilderTests: XCTestCase {
    func testHeadlineConnectsUnreadUpdatesAcrossConversations() {
        let studio = Conversation.mock(
            id: "studio",
            name: "Studio",
            isUnread: true,
            lastMessageText: "Molly: The launch notes are ready"
        )
        let nash = Conversation.mock(
            id: "nash",
            name: "Nash",
            isUnread: true,
            lastMessageText: "Nick: Dropped his favorite restaurants"
        )
        let newYorkTrip = Conversation.mock(
            id: "new-york-trip",
            name: "New York Trip",
            isUnread: true,
            lastMessageText: "Saul: Added 13 places"
        )
        let briefing = YourSpaceBriefingBuilder.make(conversations: [studio, nash, newYorkTrip])

        XCTAssertEqual(briefing.sourceCount, 3)
        XCTAssertEqual(briefing.attentionCount, 3)
        XCTAssertTrue(briefing.headline.contains("3 updates"))
        XCTAssertTrue(briefing.headline.contains("New York Trip"))
        XCTAssertFalse(briefing.headline.contains("Saul"))
        XCTAssertFalse(briefing.headline.contains("Nick"))
    }

    func testReadConversationsProduceCaughtUpHeadline() {
        let briefing = YourSpaceBriefingBuilder.make(conversations: [
            .mock(id: "family", name: "Family"),
            .mock(id: "studio", name: "Studio"),
        ])

        XCTAssertEqual(briefing.attentionCount, 0)
        XCTAssertEqual(
            briefing.headline,
            "You’re caught up. @doc is quietly keeping up with 2 groups."
        )
    }

    func testSharingKeepsConversationProvenanceWithoutInventingSender() throws {
        let briefing = YourSpaceBriefingBuilder.make(conversations: [
            .mock(
                id: "nash",
                name: "Nash",
                isUnread: true,
                lastMessageText: "Nick: Dropped his favorite restaurants"
            ),
        ])

        let update = try XCTUnwrap(briefing.recentUpdates.first)
        XCTAssertNil(update.personName)
        XCTAssertEqual(update.conversationTitle, "Nash")
        XCTAssertEqual(update.detail, "Nick: Dropped his favorite restaurants")
        XCTAssertEqual(update.shareText, "Nash: Nick: Dropped his favorite restaurants")
    }

    func testLocalContextClassifiesCommonMediaTypes() {
        XCTAssertEqual(contextItem(named: "Dinner.jpg").kind, .photo)
        XCTAssertEqual(contextItem(named: "Walkthrough.mov").kind, .video)
        XCTAssertEqual(contextItem(named: "Thought.m4a").kind, .voice)
        XCTAssertEqual(contextItem(named: "Preferences.txt").kind, .note)
        XCTAssertEqual(contextItem(named: "Brief.pdf").kind, .file)
    }

    func testRememberedFieldsBecomeSearchableContext() {
        let field = YourSpaceRememberedField(
            category: .address,
            title: "Home",
            info: "123 King Street West, Toronto"
        )
        let item = YourSpaceContextItem(rememberedField: field)

        XCTAssertEqual(item.kind, .address)
        XCTAssertEqual(item.title, "Home")
        XCTAssertEqual(item.detail, "123 King Street West, Toronto")
        XCTAssertTrue(item.isMine)
        XCTAssertFalse(item.isAutomaticallyIndexedUsefulDetail)
        XCTAssertFalse(item.matchesBrowserFilter(.address))
        XCTAssertTrue(item.matchesBrowserFilter(.all))
    }

    func testRememberedFieldsPersistLocally() throws {
        let suiteName = "YourSpaceRememberedFieldTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let field = YourSpaceRememberedField(
            category: .phone,
            title: "Mobile",
            info: "+1 416 555 0123"
        )

        YourSpaceRememberedFieldStore.save([field], defaults: defaults)

        XCTAssertEqual(YourSpaceRememberedFieldStore.fields(defaults: defaults), [field])
    }

    @MainActor
    func testShareStagerPreparesEveryPayloadWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("your-space-stager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let note = try storedFile(in: directory, name: "Note.txt", data: Data("Remember this".utf8))
        let photoData = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }.pngData()
        )
        let photo = try storedFile(in: directory, name: "Photo.png", data: photoData)
        let video = try storedFile(in: directory, name: "Clip.mov", data: Data([0, 1]))
        let voice = try storedFile(in: directory, name: "Thought.m4a", data: Data([2, 3]))
        let document = try storedFile(in: directory, name: "Brief.pdf", data: Data([4, 5]))
        let remoteURL = document.url
        let stager = YourSpaceShareStager { _, _ in remoteURL }
        let draft = TestYourSpaceDraft()

        for file in [note, photo, video, voice, document] {
            try await stager.stage(YourSpaceContextItem(local: file), in: draft)
        }
        try await stager.stage(conversationItem(kind: .link), in: draft)
        try await stager.stage(conversationItem(kind: .address), in: draft)
        try await stager.stage(conversationItem(kind: .file, attachmentKey: "remote-key"), in: draft)
        try await stager.stage(
            YourSpaceContextItem(rememberedField: YourSpaceRememberedField(
                category: .address,
                title: "Home",
                info: "123 King Street West, Toronto"
            )),
            in: draft
        )

        XCTAssertEqual(
            draft.messageText,
            "\(ConvosDocShare.invitation)\nRemember this\nhttps://example.com/context\n3728 Bear Hollow Rd, Joelton, TN 37080\nHome: 123 King Street West, Toronto"
        )
        XCTAssertEqual(draft.photoCount, 1)
        XCTAssertEqual(draft.videoNames, ["Clip.mov"])
        XCTAssertEqual(draft.fileNames, ["Thought.m4a", "Brief.pdf", "Shared.pdf"])
        XCTAssertEqual(draft.sendCount, 0)
    }

    func testAutomaticallyIndexedDetailKeepsTheSourceMessageSearchable() {
        let item = conversationItem(kind: .address)

        XCTAssertEqual(item.kind, .address)
        XCTAssertEqual(item.title, "3728 Bear Hollow Rd, Joelton, TN 37080")
        XCTAssertEqual(item.detail, "Joel said this is the cabin address.")
        XCTAssertTrue(item.isAutomaticallyIndexedUsefulDetail)
        XCTAssertTrue(item.matchesBrowserFilter(.useful))
        XCTAssertTrue(item.matchesBrowserFilter(.address))
        XCTAssertFalse(item.matchesBrowserFilter(.phone))
    }

    private func contextItem(named name: String) -> YourSpaceContextItem {
        YourSpaceContextItem(local: YourSpaceStoredFile(
            url: URL(fileURLWithPath: "/tmp/your-space-tests/\(name)"),
            name: name,
            byteCount: 1,
            addedAt: Date(timeIntervalSince1970: 0)
        ))
    }

    private func storedFile(in directory: URL, name: String, data: Data) throws -> YourSpaceStoredFile {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return YourSpaceStoredFile(url: url, name: name, byteCount: data.count, addedAt: Date())
    }

    private func conversationItem(
        kind: ContextLibraryItemKind,
        attachmentKey: String? = nil
    ) -> YourSpaceContextItem {
        YourSpaceContextItem(conversation: ContextLibraryItem(
            id: "context-\(kind.rawValue)",
            kind: kind,
            title: kind == .link
                ? "Example"
                : kind == .address
                    ? "3728 Bear Hollow Rd, Joelton, TN 37080"
                    : "Shared.pdf",
            date: Date(),
            conversationId: "destination",
            senderInboxId: "sender",
            isMine: false,
            attachmentKey: attachmentKey,
            filename: kind == .link ? nil : "Shared.pdf",
            mimeType: kind == .link ? nil : "application/pdf",
            thumbnailDataBase64: nil,
            destinationURLString: kind == .link ? "https://example.com/context" : nil,
            imageURLString: nil,
            messageText: kind == .address ? "Joel said this is the cabin address." : nil
        ))
    }
}

@MainActor
private final class TestYourSpaceDraft: YourSpaceDraftStaging {
    var messageText: String = ""
    var photoCount: Int = 0
    var videoNames: [String] = []
    var fileNames: [String] = []
    var sendCount: Int = 0

    func addPhotoAttachment(_: UIImage) {
        photoCount += 1
    }

    func addVideoAttachment(url: URL) {
        videoNames.append(url.lastPathComponent)
    }

    func addFileAttachment(url _: URL, filename: String, mimeType _: String, fileSize _: Int) {
        fileNames.append(filename)
    }
}
