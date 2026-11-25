import Foundation

public enum BranchNames {
    /// A branch name from the first words of a prompt, like
    /// "feat/add-dark-mode-toggle" or "fix/crash-on-launch".
    public static func suggest(from prompt: String) -> String {
        let filler: Set<String> = ["a", "an", "the", "to", "please", "can", "you", "could", "we", "i", "want", "let's", "lets", "and", "of", "for", "in", "on", "so", "that", "it", "this", "make"]
        let words = prompt.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
        let isFix = words.prefix(3).contains { ["fix", "bug", "broken", "crash", "crashes"].contains($0) }
        let kept = words.filter { !filler.contains($0) && $0 != "fix" }.prefix(4)
        let slug = kept.joined(separator: "-")
        return (isFix ? "fix/" : "feat/") + (slug.isEmpty ? "agent" : slug)
    }
}
