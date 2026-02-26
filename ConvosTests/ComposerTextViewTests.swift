import UIKit
import XCTest
@testable import Convos

@MainActor
final class ComposerUITextViewTests: XCTestCase {
    var textView: ComposerUITextView!
    var pastedImage: UIImage?
    var pasteCallCount: Int = 0

    override func setUp() {
        super.setUp()
        textView = ComposerUITextView()
        textView.text = "existing text"
        pastedImage = nil
        pasteCallCount = 0
        textView.onImagePasted = { [weak self] image in
            self?.pastedImage = image
            self?.pasteCallCount += 1
        }
    }

    override func tearDown() {
        textView = nil
        pastedImage = nil
        UIPasteboard.general.items = []
        super.tearDown()
    }

    func testPasteImageCallsOnImagePasted() {
        let image = UIImage(systemName: "photo")!
        UIPasteboard.general.image = image

        textView.paste(nil)

        XCTAssertNotNil(pastedImage)
        XCTAssertEqual(pasteCallCount, 1)
    }

    func testPasteImagePreservesExistingText() {
        let image = UIImage(systemName: "photo")!
        UIPasteboard.general.image = image

        textView.paste(nil)

        XCTAssertEqual(textView.text, "existing text")
    }

    func testPasteTextDoesNotCallOnImagePasted() {
        UIPasteboard.general.string = "pasted text"

        textView.paste(nil)

        XCTAssertNil(pastedImage)
        XCTAssertEqual(pasteCallCount, 0)
    }

    func testPasteEmptyClipboardDoesNotCallOnImagePasted() {
        UIPasteboard.general.items = []

        textView.paste(nil)

        XCTAssertNil(pastedImage)
        XCTAssertEqual(pasteCallCount, 0)
    }

    func testIsPastingFlagSetDuringImagePaste() {
        let image = UIImage(systemName: "photo")!
        UIPasteboard.general.image = image

        var wasPastingDuringCallback = false
        textView.onImagePasted = { [weak self] _ in
            wasPastingDuringCallback = self?.textView.isPasting ?? false
        }

        textView.paste(nil)

        XCTAssertTrue(wasPastingDuringCallback)
        XCTAssertFalse(textView.isPasting)
    }

    func testIsPastingFlagNotSetDuringTextPaste() {
        UIPasteboard.general.string = "text"

        XCTAssertFalse(textView.isPasting)

        textView.paste(nil)

        XCTAssertFalse(textView.isPasting)
    }

    func testCanPerformPasteWithImage() {
        UIPasteboard.general.image = UIImage(systemName: "photo")!

        let result = textView.canPerformAction(#selector(UITextView.paste(_:)), withSender: nil)

        XCTAssertTrue(result)
    }

    func testCanPerformPasteWithText() {
        UIPasteboard.general.string = "text"

        let result = textView.canPerformAction(#selector(UITextView.paste(_:)), withSender: nil)

        XCTAssertTrue(result)
    }

    func testCanPerformPasteWithEmptyClipboard() {
        UIPasteboard.general.items = []

        let result = textView.canPerformAction(#selector(UITextView.paste(_:)), withSender: nil)

        XCTAssertFalse(result)
    }
}
