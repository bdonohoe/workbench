import BenchKit
import Foundation
import Testing
@testable import Bench

/// The keys that answer Claude's question picker. Checked against Claude
/// Code 2.1.327: a plain question takes a number, but one with previews
/// shows them side by side, where a number only moves and Return picks.
@MainActor
struct QuestionAnswerTests {
    private let plain = CompanionQuestion(question: "Which layout?", options: [.init(label: "Rows"), .init(label: "Columns")])
    private let previews = CompanionQuestion(question: "Which layout?", options: [
        .init(label: "Rows", preview: "+----+\n| 1  |\n+----+"),
        .init(label: "Columns", preview: "+--+--+\n|1 |2 |\n+--+--+"),
    ])

    private func steps(_ questions: [CompanionQuestion], _ answers: [CompanionAnswer]) -> [AnswerStep]? {
        try? ClaudeTerminalDriver().answerSteps(questions: questions, answers: answers).get()
    }

    @Test func aPlainQuestionIsANumber() {
        #expect(steps([plain], [.init(selected: [1])]) == [.key(.digit(2))])
    }

    @Test func aPreviewQuestionIsANumberThenReturn() {
        #expect(previews.hasPreviews)
        #expect(steps([previews], [.init(selected: [1])]) == [.key(.digit(2)), .key(.returnKey)])
    }

    @Test func aNoteGoesInTheNotesBeforeReturn() {
        #expect(steps([previews], [.init(selected: [0], note: " make it compact ")])
            == [.key(.digit(1)), .key(.notes), .text("make it compact"), .key(.returnKey)])
    }

    /// An older phone has no notes field and sends your words as your own answer.
    @Test func ownWordsWithAnOptionBecomeANote() {
        #expect(steps([previews], [.init(selected: [1], other: "tighter")])
            == [.key(.digit(2)), .key(.notes), .text("tighter"), .key(.returnKey)])
    }

    @Test func ownWordsAloneCantAnswerAPreviewQuestion() {
        let result = ClaudeTerminalDriver().answerSteps(questions: [previews], answers: [.init(selected: [], other: "neither")])
        #expect((try? result.get()) == nil)
    }

    @Test func severalQuestionsEndOnSubmit() {
        #expect(steps([previews, plain], [.init(selected: [0]), .init(selected: [1])])
            == [.key(.digit(1)), .key(.returnKey), .key(.digit(2)), .key(.returnKey)])
    }

    /// Claude Code only lays previews out side by side for single choice.
    @Test func multipleChoiceIgnoresPreviews() {
        var multi = previews
        multi.multiSelect = true
        #expect(!multi.hasPreviews)
        #expect(steps([multi], [.init(selected: [0, 1])]) == [.key(.digit(1)), .key(.digit(2)), .key(.rightArrow)])
    }
}
