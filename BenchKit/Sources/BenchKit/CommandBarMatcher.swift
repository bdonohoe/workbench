import Foundation

/// Ranks the command bar's rows against what you've typed. Pure, so it can
/// be tested without the app: the app builds candidates from its projects
/// and menu actions and maps the result back to them.
public enum CommandBarMatcher {
    /// One row to rank. `keywords` are the strings it can match on, like a
    /// project's name and a worktree's branch. `recency` breaks ties, newest
    /// first. Projects get a small bonus over actions so a project whose
    /// name happens to start like an action wins.
    public struct Candidate<ID: Hashable>: Sendable where ID: Sendable {
        public var id: ID
        public var keywords: [String]
        public var recency: Date?
        public var isProject: Bool

        public init(id: ID, keywords: [String], recency: Date? = nil, isProject: Bool = false) {
            self.id = id
            self.keywords = keywords
            self.recency = recency
            self.isProject = isProject
        }
    }

    /// The ids that match `query`, best first. An empty query keeps every
    /// candidate in the order given, so the caller decides the resting
    /// order (recent projects first, then actions).
    public static func rank<ID>(_ candidates: [Candidate<ID>], query: String) -> [ID] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return candidates.map(\.id) }
        let scored: [(index: Int, score: Int, recency: Date, id: ID)] = candidates.enumerated().compactMap { index, candidate in
            guard let score = score(tokens: tokens, keywords: candidate.keywords) else { return nil }
            return (index, score + (candidate.isProject ? projectBonus : 0), candidate.recency ?? .distantPast, candidate.id)
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.recency != $1.recency { return $0.recency > $1.recency }
            return $0.index < $1.index
        }.map(\.id)
    }

    static let projectBonus = 20

    /// Every token has to match some keyword. The row's score is its weakest
    /// token's, so "bench bar" ranks by how well "bar" matches once "bench"
    /// already does.
    static func score(tokens: [String], keywords: [String]) -> Int? {
        let lowered = keywords.map { $0.lowercased() }
        var total = Int.max
        for token in tokens {
            guard let best = lowered.compactMap({ score(token: token, keyword: $0) }).max() else { return nil }
            total = min(total, best)
        }
        return total
    }

    /// A word of the keyword starting with the token beats the token appearing
    /// anywhere in it, which beats its letters merely appearing in order.
    static func score(token: String, keyword: String) -> Int? {
        guard !keyword.isEmpty else { return nil }
        if keyword.hasPrefix(token) { return 320 }
        let words = keyword.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(token) }) { return 300 }
        if keyword.contains(token) { return 200 }
        return subsequenceScore(token: token, keyword: keyword)
    }

    /// 100 for letters found in order, less the gaps between them, so
    /// tighter matches rank higher. The first letter has to start a word,
    /// so "pit" finds "Pitwall" and "bcb" finds "Bench command-bar" without
    /// every branch that happens to contain those letters tagging along.
    /// Nil when a letter is missing.
    static func subsequenceScore(token: String, keyword: String) -> Int? {
        var best: Int?
        var previous: Character?
        for (offset, character) in keyword.enumerated() {
            defer { previous = character }
            let startsWord = previous.map { !$0.isLetter && !$0.isNumber } ?? true
            guard startsWord, character == token.first,
                  let gaps = gapsMatching(token.dropFirst(), in: keyword.dropFirst(offset + 1)) else { continue }
            best = max(best ?? 0, max(1, 100 - min(gaps, 60)))
        }
        return best
    }

    /// Characters skipped while finding `rest` in order within `text`, or nil
    /// when it isn't all there.
    private static func gapsMatching(_ rest: Substring, in text: Substring) -> Int? {
        var remaining = rest
        var gaps = 0
        for character in text {
            guard let next = remaining.first else { break }
            if character == next {
                remaining.removeFirst()
            } else {
                gaps += 1
            }
        }
        return remaining.isEmpty ? gaps : nil
    }
}
