@testable import ConvosCore
import Testing

@Suite("HydratedAttachment.isMarkdownFile")
struct HydratedAttachmentIsMarkdownFileTests {
    @Test("detects .md extension")
    func mdExtension() {
        let attachment = HydratedAttachment(key: "test", filename: "README.md")
        #expect(attachment.isMarkdownFile)
    }

    @Test("detects .markdown extension")
    func markdownExtension() {
        let attachment = HydratedAttachment(key: "test", filename: "DOCS.markdown")
        #expect(attachment.isMarkdownFile)
    }

    @Test("detects .md extension case-insensitively")
    func mdExtensionUppercase() {
        let attachment = HydratedAttachment(key: "test", filename: "notes.MD")
        #expect(attachment.isMarkdownFile)
    }

    @Test("detects text/markdown mime type")
    func textMarkdownMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "text/markdown", filename: "file")
        #expect(attachment.isMarkdownFile)
    }

    @Test("detects text/x-markdown mime type")
    func textXMarkdownMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "text/x-markdown", filename: "file")
        #expect(attachment.isMarkdownFile)
    }

    @Test("returns false for non-markdown files")
    func nonMarkdown() {
        let pdf = HydratedAttachment(key: "test", filename: "document.pdf")
        let txt = HydratedAttachment(key: "test", filename: "notes.txt")
        let swift = HydratedAttachment(key: "test", filename: "main.swift")
        #expect(!pdf.isMarkdownFile)
        #expect(!txt.isMarkdownFile)
        #expect(!swift.isMarkdownFile)
    }

    @Test("returns false for nil filename and nil mime type")
    func nilFilenameAndMime() {
        let attachment = HydratedAttachment(key: "test")
        #expect(!attachment.isMarkdownFile)
    }

    @Test("returns false for non-markdown mime type")
    func nonMarkdownMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/pdf", filename: "file")
        #expect(!attachment.isMarkdownFile)
    }

    @Test("mime type detection works without filename extension")
    func mimeWithoutExtension() {
        let attachment = HydratedAttachment(key: "test", mimeType: "text/markdown", filename: "file-no-ext")
        #expect(attachment.isMarkdownFile)
    }

    @Test("extension takes priority even with wrong mime type")
    func extensionOverridesMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/octet-stream", filename: "readme.md")
        #expect(attachment.isMarkdownFile)
    }
}
