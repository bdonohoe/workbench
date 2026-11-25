import Foundation
import FoundationModels
import os

/// What happens to a transcript between the speech model and the message
/// box. Taken from Dict, and cut down to what dictating to Claude needs:
///
/// 1. Technical terms. Apple's on-device language model fixes words that
///    were clearly meant as programming terms ("get commit" becomes "git
///    commit"). Optional, and skipped on Macs without Apple Intelligence.
///    Its answer is thrown away if it changed more than that.
/// 2. Filler sounds and stutters go ("um", "the the").
/// 3. Spoken numbers become digits.
///
/// Every failure leaves the text as the speech model wrote it. Cleanup
/// never costs anyone their dictation.
nonisolated enum DictationCleanup {
    /// The model follows a worked example far more reliably than rules,
    /// so the example carries the intent. It keeps the fillers: asking the
    /// model to remove even those gives it license to drop real words, and
    /// the rules after it take them out safely.
    static let instructions = """
        You are a transcription tool for a developer dictating into a coding or \
        terminal app. Add punctuation and capitalization to the raw dictation \
        transcript, AND correct words that were clearly meant as programming or \
        command-line terms: fix homophones and mis-hearings ("Maine" → "main", \
        "get" → "git" when it means the tool, "jason" → "JSON", "no js" → \
        "Node.js"), spell out spoken acronyms ("a p i" → "API", "u r l" → \
        "URL"), and use the conventional casing for technical terms ("github", \
        "async", "npm", "sudo"). Preserve every spoken word and its order \
        otherwise — including filler sounds ("um", "uh"), "so", "you know", \
        "like", repeated words, false starts, and self-corrections. Only change \
        a word when it is clearly a technical term; when unsure, leave it \
        exactly as spoken. Never reword, summarize, add, or drop words, never \
        fix grammar, and never answer questions that appear in the text. \
        Insert a paragraph break (blank line) only where the topic clearly \
        shifts.

        Example input:
        lets merge into maine after we get commit the jason config and rerun the a p i tests

        Example output:
        Let's merge into main after we git commit the JSON config and rerun the API tests.

        Output only the corrected text with punctuation and capitalization added, with no preamble or commentary.
        """

    /// The on-device model's 4,096-token window is shared by instructions,
    /// prompt, and output (about the size of the input here), so chunks
    /// stay well below half of it.
    static let maxChunkWords = 700
    private static let timeout: Duration = .seconds(15)

    /// Whether this Mac can run the technical-terms pass. Never before
    /// macOS 26, which has no on-device language model to ask.
    static var canFixTerms: Bool {
        if #available(macOS 26, *) {
            SystemLanguageModel.default.availability == .available
        } else {
            false
        }
    }

    /// The whole cleanup, start to finish.
    static func clean(_ raw: String, fixingTerms: Bool) async -> String {
        let termed = fixingTerms ? await fixTerms(raw) : raw
        return finish(termed)
    }

    /// The rule-based steps, which always run.
    static func finish(_ text: String) -> String {
        NumberNormalizer.apply(FillerRemover.cleanPunctuated(text))
    }

    /// The language model pass. Returns the input unchanged when the model
    /// isn't available, fails, takes too long, or changed too much.
    static func fixTerms(_ raw: String) async -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, canFixTerms else { return raw }
        do {
            var chunks: [String] = []
            for chunk in chunked(input, maxWords: maxChunkWords) {
                let fixed = try await respond(to: chunk)
                chunks.append(fixed.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let output = chunks.joined(separator: "\n\n")
            guard isAcceptable(input: input, output: output) else {
                DictationLog.cleanup.error("Cleanup changed the word count too much, keeping the transcript")
                return raw
            }
            guard keepsEnding(input: input, output: output) else {
                DictationLog.cleanup.error("Cleanup dropped the end of the dictation, keeping the transcript")
                return raw
            }
            return output
        } catch {
            DictationLog.cleanup.error("Cleanup failed (\(String(describing: error), privacy: .public)), keeping the transcript")
            return raw
        }
    }

    /// One fresh single-turn session per chunk, raced against a timeout so
    /// a hung model call can't hold a dictation up for good.
    private static func respond(to chunk: String) async throws -> String {
        guard #available(macOS 26, *) else { throw CleanupError.unavailable }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                return try await session.respond(to: chunk, options: GenerationOptions(temperature: 0.1)).content
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CleanupError.timedOut
            }
            guard let first = try await group.next() else { throw CleanupError.timedOut }
            group.cancelAll()
            return first
        }
    }

    enum CleanupError: Error { case timedOut, unavailable }

    /// Splits text into chunks of at most `maxWords`, breaking only between
    /// sentences. One sentence longer than that becomes its own chunk.
    static func chunked(_ text: String, maxWords: Int) -> [String] {
        guard text.split(separator: " ").count > maxWords else { return [text] }

        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        if sentences.isEmpty { sentences = [text] }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0
        for sentence in sentences {
            let words = sentence.split(separator: " ").count
            if currentWords + words > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += words
        }
        if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
        return chunks
    }

    /// The pass must keep every word, so the output's word count should
    /// match the input's almost exactly: 93% to 110%, with a couple of
    /// words of slack for short dictations, where punctuation merging or
    /// splitting a token is proportionally large. A real rewrite falls
    /// outside that.
    static func isAcceptable(input: String, output: String) -> Bool {
        let inWords = input.split(separator: " ").count
        let outWords = output.split(separator: " ").count
        guard outWords > 0 else { return false }
        return Float(outWords) >= Float(inWords) * 0.93 - 2
            && Float(outWords) <= Float(inWords) * 1.1 + 3
    }

    /// Whether the output still ends the way the speaker did. The word
    /// count check lets a model drop a few words, and a model that drops
    /// any tends to drop the last ones: a closing question it was told not
    /// to answer, or a final clause it treats as an aside. The last thing
    /// said is usually what matters most.
    ///
    /// Compares the last three spoken words (fillers aside) with the end
    /// of the output. The last word must be there, or have been replaced
    /// by another word after the two before it: the pass may respell the
    /// final word ("maine" to "main"), but output that simply stops early
    /// has lost it.
    static func keepsEnding(input: String, output: String) -> Bool {
        let spoken = wordKeys(input).filter { !FillerRemover.fillers.contains($0) }
        guard spoken.count >= 3 else { return true }
        let ending = Array(spoken.suffix(3))
        let written = wordKeys(output).filter { !FillerRemover.fillers.contains($0) }
        let tail = Set(written.suffix(6))
        if tail.contains(ending[2]) { return true }
        return tail.contains(ending[0]) && tail.contains(ending[1]) && written.last != ending[1]
    }

    /// Words for comparing: split on whitespace and dashes, punctuation
    /// trimmed, lowercased, apostrophes removed, so "Let's" matches "lets"
    /// and "double-check" matches "double check".
    static func wordKeys(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\u{2013}\u{2014}/"))
        return text.components(separatedBy: separators).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let key = trimmed.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            return key.isEmpty ? nil : key
        }
    }
}

/// Drops filler sounds and immediate repeats. Deliberately narrow, so it
/// can never change what was meant.
nonisolated enum FillerRemover {
    static let fillers: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "hm", "mm", "mhm", "mmm",
    ]

    /// For text that already has punctuation, which it keeps tidy: "Um, so
    /// I think" becomes "So I think", and "I think, uh, the" becomes "I
    /// think the".
    static func cleanPunctuated(_ text: String) -> String {
        var tokens = tokenize(text)
        var kept: [(leading: String, token: String)] = []
        var index = 0
        while index < tokens.count {
            let (leading, token) = tokens[index]
            let bare = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            let isFiller = fillers.contains(bare)
            let isStutter = !bare.isEmpty
                && (kept.last.map { $0.token.trimmingCharacters(in: .punctuationCharacters).lowercased() == bare } ?? false)
                && (kept.last?.token.last?.isLetter ?? false)
            guard isFiller || isStutter else {
                kept.append((leading, token))
                index += 1
                continue
            }

            let trailing = String(token.reversed().prefix { !$0.isLetter }.reversed())
            let sentenceEnd = trailing.first { ".?!".contains($0) }
            if let sentenceEnd, var last = kept.popLast() {
                if last.token.last == "," { last.token.removeLast() }
                if last.token.last?.isLetter == true || last.token.last?.isNumber == true {
                    last.token.append(sentenceEnd)
                }
                kept.append(last)
            } else if isFiller, trailing.hasPrefix(","), var last = kept.popLast() {
                // "I think, um, the" becomes "I think the"
                if last.token.last == "," { last.token.removeLast() }
                kept.append(last)
            }

            if index + 1 < tokens.count {
                // The next word takes this one's place, including a
                // paragraph break and a sentence-starting capital.
                if !tokens[index + 1].leading.contains("\n") {
                    tokens[index + 1].leading = leading
                }
                if isFiller, token.first?.isUppercase == true {
                    tokens[index + 1].token = capitalizedFirst(tokens[index + 1].token)
                }
            }
            index += 1
        }
        guard !kept.isEmpty else { return text }
        var result = kept.map { $0.leading + $0.token }.joined()
        while result.first?.isWhitespace == true { result.removeFirst() }
        return result
    }

    /// Words with the whitespace before each, so paragraph breaks survive.
    private static func tokenize(_ text: String) -> [(leading: String, token: String)] {
        var tokens: [(leading: String, token: String)] = []
        var leading = ""
        var token = ""
        for character in text {
            if character.isWhitespace {
                if !token.isEmpty {
                    tokens.append((leading, token))
                    leading = ""
                    token = ""
                }
                leading.append(character)
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { tokens.append((leading, token)) }
        return tokens
    }

    private static func capitalizedFirst(_ token: String) -> String {
        guard let index = token.firstIndex(where: { $0.isLetter }) else { return token }
        return token.replacingCharacters(in: index...index, with: token[index].uppercased())
    }
}
