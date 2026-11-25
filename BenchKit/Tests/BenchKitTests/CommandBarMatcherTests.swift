import Foundation
import Testing
@testable import BenchKit

struct CommandBarMatcherTests {
    typealias Candidate = CommandBarMatcher.Candidate<String>

    @Test func emptyQueryKeepsOrder() {
        let rows = [Candidate(id: "b", keywords: ["Bench"]), Candidate(id: "a", keywords: ["Apogee"])]
        #expect(CommandBarMatcher.rank(rows, query: "   ") == ["b", "a"])
    }

    @Test func prefixBeatsSubstringBeatsSubsequence() {
        let rows = [
            Candidate(id: "subsequence", keywords: ["Backend Checks"]),  // b…e…n…c…h scattered
            Candidate(id: "substring", keywords: ["Workbench"]),
            Candidate(id: "prefix", keywords: ["Bench"]),
        ]
        #expect(CommandBarMatcher.rank(rows, query: "bench") == ["prefix", "substring", "subsequence"])
    }

    @Test func wordPrefixRanksJustUnderWholePrefix() {
        let rows = [
            Candidate(id: "word", keywords: ["Quick Notes"]),
            Candidate(id: "whole", keywords: ["Nonogame"]),
        ]
        #expect(CommandBarMatcher.rank(rows, query: "no") == ["whole", "word"])
    }

    @Test func nonMatchesAreDropped() {
        let rows = [Candidate(id: "a", keywords: ["Apogee"]), Candidate(id: "z", keywords: ["Pastry"])]
        #expect(CommandBarMatcher.rank(rows, query: "xq") == [])
        #expect(CommandBarMatcher.rank(rows, query: "pas") == ["z"])
    }

    @Test func worktreesMatchOnBranch() {
        let rows = [
            Candidate(id: "parent", keywords: ["Bench"]),
            Candidate(id: "worktree", keywords: ["Bench", "feat/command-bar"]),
        ]
        #expect(CommandBarMatcher.rank(rows, query: "command") == ["worktree"])
        #expect(CommandBarMatcher.rank(rows, query: "bench bar") == ["worktree"])
    }

    @Test func recencyBreaksTies() {
        let rows = [
            Candidate(id: "old", keywords: ["Pastry"], recency: Date(timeIntervalSince1970: 100)),
            Candidate(id: "new", keywords: ["Pitwall"], recency: Date(timeIntervalSince1970: 200)),
            Candidate(id: "never", keywords: ["Podcast"]),
        ]
        #expect(CommandBarMatcher.rank(rows, query: "p") == ["new", "old", "never"])
    }

    @Test func projectsEdgeOutActionsOnEqualMatches() {
        let rows = [
            Candidate(id: "action", keywords: ["Overview"]),
            Candidate(id: "project", keywords: ["Over"], isProject: true),
        ]
        #expect(CommandBarMatcher.rank(rows, query: "ov") == ["project", "action"])
        // A clearly better match on an action still wins.
        #expect(CommandBarMatcher.rank(rows, query: "overvi") == ["action"])
    }

    @Test func subsequenceStartsAtAWord() {
        #expect(CommandBarMatcher.subsequenceScore(token: "bcb", keyword: "bench command-bar") != nil)
        #expect(CommandBarMatcher.subsequenceScore(token: "cb", keyword: "bench command-bar") != nil)
        // p, i, t appear in order but "p" starts no word.
        #expect(CommandBarMatcher.subsequenceScore(token: "pit", keyword: "feat/version-app-have-installed") == nil)
    }

    @Test func subsequenceGapsLowerTheScore() {
        #expect(CommandBarMatcher.subsequenceScore(token: "bc", keyword: "bc")! >
                CommandBarMatcher.subsequenceScore(token: "bc", keyword: "b-------c")!)
        #expect(CommandBarMatcher.subsequenceScore(token: "bcd", keyword: "bc") == nil)
    }
}
