@testable import Convos
import XCTest

final class MessageBodyClassifierTests: XCTestCase {
    private func string(count: Int) -> String {
        String(repeating: "a", count: count)
    }

    private func newlines(_ count: Int) -> String {
        String(repeating: "\n", count: count)
    }

    // MARK: - Short

    func testEmptyIsShort() {
        XCTAssertEqual(MessageBodyClassifier.classify(""), .short)
    }

    func testTypicalShortMessageIsShort() {
        XCTAssertEqual(MessageBodyClassifier.classify("Hello world"), .short)
    }

    func testExactlyLongCharThresholdIsShort() {
        // The rule is `> longCharThreshold`, so exactly the threshold stays short.
        let text = string(count: MessageBodyClassifier.longCharThreshold)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .short)
    }

    func testExactlyShortNewlineThresholdIsShort() {
        // The rule is `> shortNewlineThreshold`, so exactly the threshold count
        // of newlines (with a short char count) stays short.
        let text = newlines(MessageBodyClassifier.shortNewlineThreshold)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .short)
    }

    // MARK: - Threshold values (lock the data-backed tuning)

    func testThresholdConstantsMatchTunedValues() {
        // Quarter's data-backed tuning: human messages over a few hundred chars
        // are rare, so long starts at 500 and pathological at 1500.
        XCTAssertEqual(MessageBodyClassifier.longCharThreshold, 500)
        XCTAssertEqual(MessageBodyClassifier.pathologicalCharThreshold, 1_500)
    }

    // MARK: - Long

    func testJustOverLongCharThresholdIsLong() {
        let text = string(count: MessageBodyClassifier.longCharThreshold + 1)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .long)
    }

    func testExactlyPathologicalCharThresholdIsLong() {
        // The rule is `> pathologicalCharThreshold`, so exactly the threshold is
        // still only long, not pathological.
        let text = string(count: MessageBodyClassifier.pathologicalCharThreshold)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .long)
    }

    func testShortCharCountWithManyNewlinesIsLong() {
        // Few characters but more than 30 hard line breaks (e.g. a code snippet
        // or poem) forces many line fragments, so it is treated as long.
        let text = "x" + newlines(MessageBodyClassifier.shortNewlineThreshold + 1)
        XCTAssertLessThanOrEqual(text.count, MessageBodyClassifier.longCharThreshold)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .long)
    }

    func testJustOverShortNewlineThresholdIsLong() {
        let text = newlines(MessageBodyClassifier.shortNewlineThreshold + 1)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .long)
    }

    // MARK: - Pathological

    func testJustOverPathologicalCharThresholdIsPathological() {
        let text = string(count: MessageBodyClassifier.pathologicalCharThreshold + 1)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .pathological)
    }

    func testVeryLargeBodyIsPathological() {
        let text = string(count: MessageBodyClassifier.pathologicalCharThreshold * 3)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .pathological)
    }

    func testPathologicalCharCountTakesPrecedenceOverNewlineRule() {
        // A body over the pathological char threshold is pathological even if it
        // also has many newlines (char threshold is checked first).
        let text = string(count: MessageBodyClassifier.pathologicalCharThreshold + 1)
            + newlines(MessageBodyClassifier.shortNewlineThreshold + 5)
        XCTAssertEqual(MessageBodyClassifier.classify(text), .pathological)
    }
}
