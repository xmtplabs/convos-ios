@testable import ConvosCore
import Foundation
import Testing

@Suite("Markdown Stripping Tests")
struct MarkdownStrippingTests {
    // MARK: - Basic Formatting Tests

    @Test("Plain text returns unchanged")
    func plainTextReturnsUnchanged() {
        let text = "This is plain text"
        #expect(text.strippingMarkdown == "This is plain text")
    }

    @Test("Empty string returns empty")
    func emptyStringReturnsEmpty() {
        let text = ""
        #expect(text.strippingMarkdown == "")
    }

    @Test("Bold formatting strips to plain text")
    func boldFormattingStrips() {
        let text = "This is **bold** text"
        #expect(text.strippingMarkdown == "This is bold text")
    }

    @Test("Double bold formatting strips correctly")
    func doubleBoldFormatting() {
        let text = "**First bold** and **second bold**"
        #expect(text.strippingMarkdown == "First bold and second bold")
    }

    @Test("Italic formatting strips to plain text")
    func italicFormattingStrips() {
        let text = "This is *italic* text"
        #expect(text.strippingMarkdown == "This is italic text")
    }

    @Test("Italic with underscores strips correctly")
    func italicWithUnderscores() {
        let text = "This is _italic_ text"
        #expect(text.strippingMarkdown == "This is italic text")
    }

    @Test("Strikethrough formatting strips to plain text")
    func strikethroughFormattingStrips() {
        let text = "This is ~~strikethrough~~ text"
        #expect(text.strippingMarkdown == "This is strikethrough text")
    }

    @Test("Inline code formatting strips to plain text")
    func inlineCodeFormattingStrips() {
        let text = "This is `code` text"
        #expect(text.strippingMarkdown == "This is code text")
    }

    // MARK: - Mixed Formatting Tests

    @Test("Mixed bold and italic strips correctly")
    func mixedBoldAndItalic() {
        let text = "**bold** and *italic*"
        #expect(text.strippingMarkdown == "bold and italic")
    }

    @Test("Mixed bold, italic, and code strips correctly")
    func mixedBoldItalicCode() {
        let text = "**bold**, *italic*, and `code`"
        #expect(text.strippingMarkdown == "bold, italic, and code")
    }

    @Test("All formatting types together")
    func allFormattingTypesTogether() {
        let text = "**bold**, *italic*, ~~strikethrough~~, and `code`"
        #expect(text.strippingMarkdown == "bold, italic, strikethrough, and code")
    }

    @Test("Bold and italic combined strips correctly")
    func boldAndItalicCombined() {
        let text = "***bold and italic***"
        #expect(text.strippingMarkdown == "bold and italic")
    }

    @Test("Bold italic alternate syntax")
    func boldItalicAlternateSyntax() {
        let text = "**_bold and italic_**"
        #expect(text.strippingMarkdown == "bold and italic")
    }

    // MARK: - Nested Formatting Tests

    @Test("Nested bold and italic strips correctly")
    func nestedBoldAndItalic() {
        let text = "**bold with *italic* inside**"
        #expect(text.strippingMarkdown == "bold with italic inside")
    }

    @Test("Nested formatting preserves text order")
    func nestedFormattingPreservesOrder() {
        let text = "*italic with **bold** inside*"
        #expect(text.strippingMarkdown == "italic with bold inside")
    }

    @Test("Deeply nested formatting")
    func deeplyNestedFormatting() {
        let text = "**bold *italic `code`***"
        #expect(text.strippingMarkdown == "bold italic code")
    }

    // MARK: - Link Tests

    @Test("Markdown links strip to link text only")
    func markdownLinksStripToText() {
        let text = "Check out [this link](https://example.com)"
        #expect(text.strippingMarkdown == "Check out this link")
    }

    @Test("Multiple markdown links strip correctly")
    func multipleMarkdownLinks() {
        let text = "[Link one](https://one.com) and [Link two](https://two.com)"
        #expect(text.strippingMarkdown == "Link one and Link two")
    }

    @Test("Link with formatted text")
    func linkWithFormattedText() {
        let text = "Visit [**bold link**](https://example.com)"
        #expect(text.strippingMarkdown == "Visit bold link")
    }

    @Test("Plain URL preserved as text")
    func plainURLPreserved() {
        let text = "Visit https://example.com"
        #expect(text.strippingMarkdown == "Visit https://example.com")
    }

    @Test("Email address preserved")
    func emailAddressPreserved() {
        let text = "Contact me@example.com"
        #expect(text.strippingMarkdown == "Contact me@example.com")
    }

    // MARK: - Multi-line Tests

    @Test("Multiple lines with markdown strip correctly")
    func multipleLinesWithMarkdown() {
        let text = "**Line one**\n*Line two*"
        #expect(text.strippingMarkdown == "Line one\nLine two")
    }

    @Test("Multi-line with mixed formatting")
    func multiLineWithMixedFormatting() {
        let text = "**Bold** on first line\n`Code` on second line\n~~Strike~~ on third"
        #expect(text.strippingMarkdown == "Bold on first line\nCode on second line\nStrike on third")
    }

    @Test("Text with line breaks preserves line breaks")
    func textWithLineBreaksPreservesBreaks() {
        let text = "Line 1\n\nLine 2"
        #expect(text.strippingMarkdown == "Line 1\n\nLine 2")
    }

    // MARK: - Edge Cases

    @Test("Single asterisk not treated as italic")
    func singleAsteriskNotItalic() {
        let text = "This * is not italic"
        #expect(text.strippingMarkdown == "This * is not italic")
    }

    @Test("Single underscore not treated as italic")
    func singleUnderscoreNotItalic() {
        let text = "This_is_not_italic"
        #expect(text.strippingMarkdown == "This_is_not_italic")
    }

    @Test("Incomplete markdown preserved")
    func incompleteMarkdownPreserved() {
        let text = "**This is incomplete"
        #expect(text.strippingMarkdown == "**This is incomplete")
    }

    @Test("Mismatched formatting markers")
    func mismatchedFormattingMarkers() {
        let text = "**bold _italic**"
        let result = text.strippingMarkdown
        #expect(!result.contains("**"))
    }

    @Test("Text with backticks but not code")
    func textWithBackticksNotCode() {
        let text = "This ` is not ` code"
        #expect(text.strippingMarkdown == "This is not code")
    }

    @Test("Only markdown characters")
    func onlyMarkdownCharacters() {
        let text = "**"
        #expect(text.strippingMarkdown == "**")
    }

    // MARK: - Special Characters

    @Test("Text with emoji preserves emoji")
    func textWithEmojiPreservesEmoji() {
        let text = "Hello 👋 **world** 🌍"
        #expect(text.strippingMarkdown == "Hello 👋 world 🌍")
    }

    @Test("Text with unicode characters")
    func textWithUnicodeCharacters() {
        let text = "**Café** and *naïve*"
        #expect(text.strippingMarkdown == "Café and naïve")
    }

    @Test("Text with special punctuation")
    func textWithSpecialPunctuation() {
        let text = "**Hello!** How are you? I'm fine."
        #expect(text.strippingMarkdown == "Hello! How are you? I'm fine.")
    }

    // MARK: - Whitespace Handling

    @Test("Leading whitespace preserved")
    func leadingWhitespacePreserved() {
        let text = "  **bold** text"
        #expect(text.strippingMarkdown == "  bold text")
    }

    @Test("Trailing whitespace preserved")
    func trailingWhitespacePreserved() {
        let text = "**bold** text  "
        #expect(text.strippingMarkdown == "bold text  ")
    }

    @Test("Whitespace around formatting preserved")
    func whitespaceAroundFormattingPreserved() {
        let text = "text **bold** text"
        #expect(text.strippingMarkdown == "text bold text")
    }

    @Test("Tabs preserved")
    func tabsPreserved() {
        let text = "**bold**\ttext"
        #expect(text.strippingMarkdown == "bold\ttext")
    }

    // MARK: - Realistic Message Scenarios

    @Test("Typical message with bold")
    func typicalMessageWithBold() {
        let text = "Hey! I'll be there at **3pm** tomorrow."
        #expect(text.strippingMarkdown == "Hey! I'll be there at 3pm tomorrow.")
    }

    @Test("Message with code snippet")
    func messageWithCodeSnippet() {
        let text = "Try running `npm install` to fix it"
        #expect(text.strippingMarkdown == "Try running npm install to fix it")
    }

    @Test("Message with link")
    func messageWithLink() {
        let text = "Check this out: [Cool Article](https://example.com/article)"
        #expect(text.strippingMarkdown == "Check this out: Cool Article")
    }

    @Test("Message with multiple formatting types")
    func messageWithMultipleFormattingTypes() {
        let text = "**Important:** Please review *before* sending. Use `CTRL+S` to save."
        #expect(text.strippingMarkdown == "Important: Please review before sending. Use CTRL+S to save.")
    }

    @Test("Message with strikethrough correction")
    func messageWithStrikethroughCorrection() {
        let text = "Meet at ~~2pm~~ **3pm** instead"
        #expect(text.strippingMarkdown == "Meet at 2pm 3pm instead")
    }

    // MARK: - Reaction Source Formatting Tests

    @Test("Reaction source with markdown truncates correctly")
    func reactionSourceWithMarkdownTruncates() {
        let text: String? = "**This is a very long message** with *lots* of `markdown`"
        let formatted = text.formattedAsReactionSource(maxLength: 20)
        #expect(formatted.hasPrefix("'"))
        #expect(formatted.hasSuffix("'") || formatted.hasSuffix("…'"))
        #expect(!formatted.contains("**"))
        #expect(!formatted.contains("*"))
    }

    @Test("Reaction source with nil text returns fallback")
    func reactionSourceWithNilText() {
        let text: String? = nil
        let formatted = text.formattedAsReactionSource()
        #expect(formatted == "a message")
    }

    @Test("Reaction source with empty text returns fallback")
    func reactionSourceWithEmptyText() {
        let text: String? = ""
        let formatted = text.formattedAsReactionSource()
        #expect(formatted == "a message")
    }

    @Test("Reaction source short text not truncated")
    func reactionSourceShortTextNotTruncated() {
        let text: String? = "**Hi**"
        let formatted = text.formattedAsReactionSource()
        #expect(formatted == "'Hi'")
    }

    @Test("Reaction source exactly at limit")
    func reactionSourceExactlyAtLimit() {
        let text: String? = String(repeating: "a", count: 30)
        let formatted = text.formattedAsReactionSource(maxLength: 30)
        #expect(formatted == "'\(String(repeating: "a", count: 30))'")
    }

    @Test("Reaction source over limit gets truncated")
    func reactionSourceOverLimitTruncated() {
        let text: String? = String(repeating: "a", count: 35)
        let formatted = text.formattedAsReactionSource(maxLength: 30)
        #expect(formatted == "'\(String(repeating: "a", count: 30))…'")
    }
}
