@testable import Convos
import ConvosComposer
import XCTest

final class AttachmentSharePayloadTests: XCTestCase {
    // MARK: - sanitizeFilename

    func testLeadingDotDoesNotProduceHiddenFile() {
        let result = AttachmentSharePayload.sanitizeFilename(".secret")
        XCTAssertFalse(result.hasPrefix("."), "Sanitized name must not start with a dot")
        XCTAssertEqual(result, "secret")
    }

    func testTrailingDotIsStripped() {
        XCTAssertEqual(AttachmentSharePayload.sanitizeFilename("report."), "report")
    }

    func testLeadingAndTrailingUnderscoresAreStripped() {
        XCTAssertEqual(AttachmentSharePayload.sanitizeFilename("__draft__"), "draft")
    }

    func testEmptyInputFallsBackToAttachment() {
        XCTAssertEqual(AttachmentSharePayload.sanitizeFilename(""), "attachment")
    }

    func testAllStrippableInputFallsBackToAttachment() {
        XCTAssertEqual(AttachmentSharePayload.sanitizeFilename("..__  "), "attachment")
    }

    func testNormalTitleIsPreserved() {
        XCTAssertEqual(AttachmentSharePayload.sanitizeFilename("My Report"), "My Report")
    }

    func testDisallowedCharactersBecomeUnderscores() {
        XCTAssertEqual(AttachmentSharePayload.sanitizeFilename("Q3/Results"), "Q3_Results")
    }

    func testLengthIsCappedAndNotLeftWithTrailingDot() {
        let raw = String(repeating: "a", count: 63) + ".tail"
        let result = AttachmentSharePayload.sanitizeFilename(raw)
        XCTAssertLessThanOrEqual(result.count, 64)
        XCTAssertFalse(result.hasSuffix("."), "Capping must not leave a trailing dot")
    }

    // MARK: - htmlShareExtension

    func testHTMLExtensionIsPreserved() {
        let url = URL(fileURLWithPath: "/tmp/report.html")
        XCTAssertEqual(AttachmentSharePayload.htmlShareExtension(for: url), "html")
    }

    func testHTMExtensionIsPreserved() {
        let url = URL(fileURLWithPath: "/tmp/report.htm")
        XCTAssertEqual(AttachmentSharePayload.htmlShareExtension(for: url), "htm")
    }

    func testUppercaseHTMLExtensionIsNormalized() {
        let url = URL(fileURLWithPath: "/tmp/report.HTML")
        XCTAssertEqual(AttachmentSharePayload.htmlShareExtension(for: url), "html")
    }

    func testNonHTMLExtensionIsForcedToHTML() {
        let url = URL(fileURLWithPath: "/tmp/report.txt")
        XCTAssertEqual(AttachmentSharePayload.htmlShareExtension(for: url), "html")
    }

    func testMissingExtensionIsForcedToHTML() {
        let url = URL(fileURLWithPath: "/tmp/report")
        XCTAssertEqual(AttachmentSharePayload.htmlShareExtension(for: url), "html")
    }

    // MARK: - Combined share filename

    func testHiddenTitleWithTextSourceYieldsVisibleHTMLName() {
        let basename = AttachmentSharePayload.sanitizeFilename(".secret")
        let ext = AttachmentSharePayload.htmlShareExtension(for: URL(fileURLWithPath: "/tmp/report.txt"))
        XCTAssertEqual("\(basename).\(ext)", "secret.html")
    }
}
