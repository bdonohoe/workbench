import Testing
@testable import Bench

/// The checks that decide whether the language model's cleanup is kept,
/// and the rules that run after it. From Dict's tests of the same code.
struct DictationCleanupTests {
    private func words(_ count: Int) -> String { [String](repeating: "word", count: count).joined(separator: " ") }

    // MARK: chunked

    @Test func shortTextIsASingleChunk() {
        let text = "Hello world. This is short."
        #expect(DictationCleanup.chunked(text, maxWords: 700) == [text])
    }

    @Test func longTextSplitsBetweenSentences() {
        let sentence = "One two three four five six seven eight nine ten."
        let text = [String](repeating: sentence, count: 100).joined(separator: " ")
        let chunks = DictationCleanup.chunked(text, maxWords: 700)
        #expect(chunks.count == 2)
        for chunk in chunks {
            #expect(chunk.split(separator: " ").count <= 700)
            #expect(chunk.hasSuffix("."))
        }
        #expect(chunks.map { $0.split(separator: " ").count }.reduce(0, +) == 1000)
    }

    // MARK: isAcceptable

    @Test func acceptsNearIdenticalWordCount() {
        #expect(DictationCleanup.isAcceptable(input: words(100), output: words(97)))
    }

    @Test func rejectsEmptyOutput() {
        #expect(!DictationCleanup.isAcceptable(input: "some real words here", output: ""))
    }

    @Test func rejectsOutputThatLostWords() {
        #expect(!DictationCleanup.isAcceptable(input: words(100), output: words(85)))
        #expect(!DictationCleanup.isAcceptable(input: words(100), output: words(50)))
    }

    @Test func rejectsOutputThatAddedWords() {
        #expect(!DictationCleanup.isAcceptable(input: words(100), output: words(120)))
    }

    @Test func allowsSlackOnShortDictations() {
        #expect(DictationCleanup.isAcceptable(input: words(12), output: words(10)))
    }

    // MARK: keepsEnding

    @Test func keepsEndingAcceptsPunctuationOnlyChanges() {
        #expect(DictationCleanup.keepsEnding(input: "can you look into that and tell me what you find",
                                             output: "Can you look into that and tell me what you find?"))
    }

    @Test func keepsEndingRejectsADroppedFinalClause() {
        // Within the word-count slack, so only this check catches it.
        let input = "okay so I think the problem is in the release tail logic, we keep cutting off the last few words when I let go of the key, can you look into that"
        let output = "Okay, so I think the problem is in the release tail logic, we keep cutting off the last few words when I let go of the key, can you look?"
        #expect(DictationCleanup.isAcceptable(input: input, output: output))
        #expect(!DictationCleanup.keepsEnding(input: input, output: output))
    }

    @Test func keepsEndingRejectsADroppedLastWord() {
        #expect(!DictationCleanup.keepsEnding(input: "send the build to the team on Friday afternoon",
                                              output: "Send the build to the team on Friday."))
    }

    @Test func keepsEndingAllowsARespelledLastWord() {
        #expect(DictationCleanup.keepsEnding(input: "commit the change and push it to maine",
                                             output: "Commit the change and push it to main."))
    }

    @Test func keepsEndingIgnoresATrailingFiller() {
        #expect(DictationCleanup.keepsEnding(input: "I'll send the notes over tomorrow um",
                                             output: "I'll send the notes over tomorrow."))
    }

    // MARK: the rules

    @Test func rulesDropFillersAndWriteNumbersAsDigits() {
        #expect(DictationCleanup.finish("Um, so run the the tests twenty five times.") == "So run the tests 25 times.")
    }

    @Test func blankInputComesBackUnchanged() async {
        #expect(await DictationCleanup.fixTerms("   ") == "   ")
    }
}

struct DictationFillerRemoverTests {
    @Test func dropsLeadingFillerAndCapitalizesTheNextWord() {
        #expect(FillerRemover.cleanPunctuated("Um, so I think it works.") == "So I think it works.")
    }

    @Test func dropsFillerBetweenCommas() {
        #expect(FillerRemover.cleanPunctuated("I think, uh, the update is solid.") == "I think the update is solid.")
    }

    @Test func movesASentenceEndBackToThePreviousWord() {
        #expect(FillerRemover.cleanPunctuated("It works, um. Next one.") == "It works. Next one.")
    }

    @Test func keepsParagraphBreaks() {
        #expect(FillerRemover.cleanPunctuated("First part.\n\nUm, second part.") == "First part.\n\nSecond part.")
    }

    @Test func dropsStuttersWithoutChangingCase() {
        #expect(FillerRemover.cleanPunctuated("I I think the the plan works.") == "I think the plan works.")
    }

    @Test func leavesCleanTextAlone() {
        let text = "So I think the update is like really solid, you know?"
        #expect(FillerRemover.cleanPunctuated(text) == text)
    }

    @Test func keepsWordsThatOnlyLookLikeFillers() {
        #expect(FillerRemover.cleanPunctuated("The umbrella is here.") == "The umbrella is here.")
    }

    @Test func neverReturnsEmpty() {
        #expect(FillerRemover.cleanPunctuated("Um.") == "Um.")
    }
}
