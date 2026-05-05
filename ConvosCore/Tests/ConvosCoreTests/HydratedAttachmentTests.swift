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

    @Test("detects markdown mime types case-insensitively")
    func markdownMimeCaseInsensitive() {
        let markdown = HydratedAttachment(key: "test", mimeType: "Text/Markdown", filename: "file")
        let xMarkdown = HydratedAttachment(key: "test", mimeType: "TEXT/X-MARKDOWN", filename: "file")
        #expect(markdown.isMarkdownFile)
        #expect(xMarkdown.isMarkdownFile)
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

@Suite("HydratedAttachment.isHTMLFile")
struct HydratedAttachmentIsHTMLFileTests {
    @Test("detects .html extension")
    func htmlExtension() {
        let attachment = HydratedAttachment(key: "test", filename: "page.html")
        #expect(attachment.isHTMLFile)
    }

    @Test("detects .htm extension")
    func htmExtension() {
        let attachment = HydratedAttachment(key: "test", filename: "legacy.htm")
        #expect(attachment.isHTMLFile)
    }

    @Test("detects .html extension case-insensitively")
    func htmlExtensionUppercase() {
        let attachment = HydratedAttachment(key: "test", filename: "INDEX.HTML")
        #expect(attachment.isHTMLFile)
    }

    @Test("detects text/html mime type")
    func textHTMLMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "text/html", filename: "file")
        #expect(attachment.isHTMLFile)
    }

    @Test("detects text/html mime type case-insensitively")
    func textHTMLMimeCaseInsensitive() {
        let attachment = HydratedAttachment(key: "test", mimeType: "Text/HTML", filename: "file")
        #expect(attachment.isHTMLFile)
    }

    @Test("returns false for non-html files")
    func nonHTML() {
        let pdf = HydratedAttachment(key: "test", filename: "document.pdf")
        let md = HydratedAttachment(key: "test", filename: "readme.md")
        #expect(!pdf.isHTMLFile)
        #expect(!md.isHTMLFile)
    }

    @Test("returns false for nil filename and nil mime type")
    func nilFilenameAndMime() {
        let attachment = HydratedAttachment(key: "test")
        #expect(!attachment.isHTMLFile)
    }

    @Test("mime type detection works without filename extension")
    func mimeWithoutExtension() {
        let attachment = HydratedAttachment(key: "test", mimeType: "text/html", filename: "file-no-ext")
        #expect(attachment.isHTMLFile)
    }

    @Test("extension takes priority even with wrong mime type")
    func extensionOverridesMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/octet-stream", filename: "page.html")
        #expect(attachment.isHTMLFile)
    }
}

@Suite("HydratedAttachment.isArtifactBundle")
struct HydratedAttachmentIsArtifactBundleTests {
    @Test("detects .artifact extension")
    func artifactExtension() {
        let attachment = HydratedAttachment(key: "test", filename: "paris.artifact")
        #expect(attachment.isArtifactBundle)
    }

    @Test("detects .artifact extension case-insensitively")
    func artifactExtensionUppercase() {
        let attachment = HydratedAttachment(key: "test", filename: "DIMSUM.ARTIFACT")
        #expect(attachment.isArtifactBundle)
    }

    @Test("detects application/x-convos-artifact mime type")
    func convosArtifactMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/x-convos-artifact", filename: "file")
        #expect(attachment.isArtifactBundle)
    }

    @Test("detects mime type case-insensitively")
    func convosArtifactMimeCaseInsensitive() {
        let attachment = HydratedAttachment(key: "test", mimeType: "Application/X-Convos-Artifact", filename: "file")
        #expect(attachment.isArtifactBundle)
    }

    @Test("returns false for plain HTML and zip")
    func nonArtifact() {
        let html = HydratedAttachment(key: "test", filename: "page.html")
        let zip = HydratedAttachment(key: "test", filename: "archive.zip")
        let pdf = HydratedAttachment(key: "test", filename: "doc.pdf")
        #expect(!html.isArtifactBundle)
        #expect(!zip.isArtifactBundle)
        #expect(!pdf.isArtifactBundle)
    }

    @Test("returns false for nil filename and nil mime type")
    func nilFilenameAndMime() {
        let attachment = HydratedAttachment(key: "test")
        #expect(!attachment.isArtifactBundle)
    }

    @Test("mime type detection works without filename extension")
    func mimeWithoutExtension() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/x-convos-artifact", filename: "bundle")
        #expect(attachment.isArtifactBundle)
    }

    @Test("extension takes priority even with wrong mime type")
    func extensionOverridesMime() {
        let attachment = HydratedAttachment(key: "test", mimeType: "application/octet-stream", filename: "tents.artifact")
        #expect(attachment.isArtifactBundle)
    }
}
