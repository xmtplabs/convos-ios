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

    func testEmptyHintsAreIgnored() {
        let viewModel = makeViewModel()
        viewModel.rollDice(hints: [])
        XCTAssertTrue(viewModel.composerText.isEmpty)
        XCTAssertEqual(viewModel.composerTextSource, .manual)
        XCTAssertEqual(viewModel.promptHintTapCount, 0)
    }
}
