@testable import Convos
import ConvosCore
import XCTest

/// Coverage for the agent builder's dice control: visibility preconditions,
/// random non-repeating rolls, the visibility-vs-metrics source split, and the
/// per-session tap count.
@MainActor
final class AgentBuilderViewModelDiceTests: XCTestCase {
    private func makeViewModel() -> AgentBuilderViewModel {
        AgentBuilderViewModel(session: ConvosClient.mock().session)
    }

    func testDiceAllowedOnEmptyDraft() {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.allowsDiceRoll, "An empty draft should permit a roll")
        XCTAssertEqual(viewModel.composerTextSource, .manual)
    }

    func testManualTypingHidesDice() {
        let viewModel = makeViewModel()
        viewModel.composerTextBinding.wrappedValue = "a hand-typed prompt"
        XCTAssertEqual(viewModel.composerTextSource, .manual,
                       "A user keystroke should mark the source manual")
        XCTAssertFalse(viewModel.allowsDiceRoll,
                       "Manual non-empty text should hide the dice")
    }

    func testDiceStaysVisibleWhileRolling() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: ["one", "two", "three"])
        XCTAssertFalse(viewModel.composerText.isEmpty, "A roll drops a hint into the composer")
        XCTAssertEqual(viewModel.composerTextSource, .dice)
        XCTAssertTrue(viewModel.allowsDiceRoll,
                      "Dice-sourced text should keep the dice visible for re-rolls")
    }

    func testRollAvoidsImmediateRepeat() {
        let viewModel = makeViewModel()
        let hints = ["a", "b", "c"]
        var previous: String?
        for _ in 0..<40 {
            viewModel.rollDice(hints: hints)
            let current = viewModel.composerText
            XCTAssertNotEqual(current, previous, "A roll must not repeat the current hint")
            previous = current
        }
    }

    func testSingleHintRollsThatHint() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: ["only"])
        XCTAssertEqual(viewModel.composerText, "only")
        viewModel.rollDice(hints: ["only"])
        XCTAssertEqual(viewModel.composerText, "only",
                       "With a single hint, a re-roll re-applies it rather than stalling")
    }

    func testFromPromptHintSurvivesEditAndResetsOnClear() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: ["seeded prompt"])
        XCTAssertTrue(viewModel.fromPromptHint, "A roll sets the metrics flag")

        viewModel.composerTextBinding.wrappedValue = "seeded prompt with edits"
        XCTAssertTrue(viewModel.fromPromptHint, "Editing must not clear the metrics flag")
        XCTAssertEqual(viewModel.composerTextSource, .manual)

        viewModel.composerTextBinding.wrappedValue = ""
        XCTAssertFalse(viewModel.fromPromptHint, "Clearing the composer resets the metrics flag")
    }

    func testTapCountAccumulates() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: ["a", "b"])
        viewModel.rollDice(hints: ["a", "b"])
        viewModel.rollDice(hints: ["a", "b"])
        XCTAssertEqual(viewModel.promptHintTapCount, 3)
    }

    func testEchoedSetDoesNotRegisterPhantomEdit() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: ["seeded prompt"])
        XCTAssertEqual(viewModel.composerTextSource, .dice)

        // A re-presented sheet reconstructs the text field, which echoes the
        // current value back through the binding with no real keystroke. That
        // must not count as an edit, otherwise the first dice tap after a reopen
        // hides the dice.
        viewModel.composerTextBinding.wrappedValue = viewModel.composerText
        XCTAssertEqual(viewModel.composerTextSource, .dice,
                       "An echoed no-op write must not flip the source to manual")
        XCTAssertTrue(viewModel.allowsDiceRoll,
                      "The dice must stay visible after an echoed no-op write")
        XCTAssertTrue(viewModel.fromPromptHint,
                      "An echoed no-op write must not clear the metrics flag")
    }

    func testReopenThenRollKeepsDiceVisible() {
        let viewModel = makeViewModel()
        let hints = ["one", "two", "three"]
        viewModel.rollDice(hints: hints)

        // Simulate the sheet reopen: the reconstructed field echoes the held
        // hint, then the user taps the dice once.
        viewModel.composerTextBinding.wrappedValue = viewModel.composerText
        viewModel.rollDice(hints: hints)
        XCTAssertEqual(viewModel.composerTextSource, .dice)
        XCTAssertTrue(viewModel.allowsDiceRoll,
                      "The first dice tap after a reopen must keep the dice visible")
    }

    func testGenuineEditStillHidesDiceAfterRoll() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: ["seeded prompt"])
        viewModel.composerTextBinding.wrappedValue = "seeded prompt edited by hand"
        XCTAssertEqual(viewModel.composerTextSource, .manual,
                       "A real keystroke that changes the text must mark the source manual")
        XCTAssertFalse(viewModel.allowsDiceRoll,
                       "Genuinely edited text should hide the dice")
    }

    func testEmptyHintsAreIgnored() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: [])
        XCTAssertTrue(viewModel.composerText.isEmpty)
        XCTAssertEqual(viewModel.composerTextSource, .manual)
        XCTAssertEqual(viewModel.promptHintTapCount, 0)
    }
}
