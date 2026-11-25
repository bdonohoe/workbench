import Foundation

/// Looks over the command typed in Settings > Claude > Command for mistakes
/// that would break Claude tabs, or start Claude without Workbench's own
/// options. It only warns: the command still runs as typed.
nonisolated enum ClaudeCommandCheck {
    /// Options Workbench passes itself, or that stop a tab from working
    /// like a normal Claude session.
    static let managedOptions: [String: String] = [
        "-p": "-p makes Claude print one reply and quit.",
        "--print": "--print makes Claude print one reply and quit.",
        "-r": "Workbench resumes sessions itself, so leave out -r.",
        "--resume": "Workbench resumes sessions itself, so leave out --resume.",
        "-c": "Workbench resumes sessions itself, so leave out -c.",
        "--continue": "Workbench resumes sessions itself, so leave out --continue.",
    ]

    /// Plain-language problems with `command`, most serious first. Empty
    /// when it looks fine. `exists` says whether a program name or path
    /// can be run on this Mac.
    static func warnings(for command: String, exists: (String) -> Bool = programExists) -> [String] {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return [] }
        let scan = scan(command)
        var result: [String] = []

        if let quote = scan.openQuote {
            result.append("A \(quote) quote isn't closed, so the tab will wait for more input instead of starting Claude.")
        } else if command.hasSuffix("\\") {
            result.append("It ends with \\, so the tab will wait for more input instead of starting Claude.")
        }
        if scan.hasComment {
            result.append("Everything after # is ignored by the shell, including the options Workbench adds, so Workbench won't see what Claude is doing.")
        }
        if let op = scan.operators.first {
            result.append("Workbench adds its options to the end of the line, so with \(op) they reach the last command instead of claude.")
        }
        // The program is the first word that isn't a VAR=value setting.
        if scan.openQuote == nil,
           let program = scan.words.first(where: { !isAssignment($0) }), !exists(program) {
            result.append("Workbench can't find \(program) on this Mac. If it's a shell alias or function, you can ignore this.")
        }
        var seen = Set<String>()
        for word in scan.words {
            let name = String(word.split(separator: "=", maxSplits: 1).first ?? "")
            if let note = managedOptions[name], seen.insert(note).inserted { result.append(note) }
        }
        return result
    }

    /// Whether `program` can be run: a path to an executable file, or a
    /// name found on the shell's PATH.
    static func programExists(_ program: String) -> Bool {
        if program.contains("/") {
            return FileManager.default.isExecutableFile(atPath: (program as NSString).expandingTildeInPath)
        }
        return Tools.path(program) != nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private struct Scan {
        var words: [String] = []
        var operators: [String] = []
        var hasComment = false
        var openQuote: String?
    }

    /// Splits the command into words the way a shell roughly would,
    /// noting quotes, comments, and operators that sit outside quotes.
    private static func scan(_ command: String) -> Scan {
        var scan = Scan()
        var word = ""
        var inWord = false
        var quote: Character?
        var chars = Array(command)[...]

        func endWord() {
            if inWord { scan.words.append(word) }
            word = ""
            inWord = false
        }

        while let c = chars.popFirst() {
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\", q == "\"", let next = chars.popFirst() { word.append(next) }
                else { word.append(c) }
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                inWord = true
            case "\\":
                if let next = chars.popFirst() { word.append(next) }
                inWord = true
            case " ", "\t":
                endWord()
            case "#" where !inWord:
                scan.hasComment = true
                endWord()
                return scan
            case ";", "|", "&":
                endWord()
                var op = String(c)
                if let next = chars.first, next == c, c != ";" { op.append(chars.removeFirst()) }
                scan.operators.append(op)
            default:
                word.append(c)
                inWord = true
            }
        }
        endWord()
        if let quote { scan.openQuote = quote == "'" ? "single" : "double" }
        return scan
    }
}
