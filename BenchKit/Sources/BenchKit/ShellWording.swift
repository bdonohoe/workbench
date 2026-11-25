import Foundation

/// Plain words for common shell commands that read or search, for when
/// Claude runs one without describing it: `sed -n 1,80p Theme.swift`
/// becomes "Reading Theme.swift". Anything else returns nil, and the
/// command is shown as it is.
enum ShellWording {
    static func describe(_ command: String) -> String? {
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // Commands joined by && or ;, each cut at its first pipe: only the
        // start of a pipeline says what's being read.
        var commands: [[String]] = [[]]
        var piped = false
        for token in tokens(line) {
            switch token {
            case "&&", "||", ";":
                commands.append([])
                piped = false
            case "|":
                piped = true
            default:
                if !piped { commands[commands.count - 1].append(token) }
            }
        }
        // Skip a leading `cd somewhere`; the rest is the part that matters.
        guard let words = commands.first(where: { !$0.isEmpty && $0.first != "cd" }) else { return nil }
        guard let program = words.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return nil }
        let args = Array(words.dropFirst())
        let plain = args.filter { !$0.hasPrefix("-") }

        switch program {
        case "wc":
            return plain.last.map { "Counting lines in \(name($0))" }
        case "cat", "head", "tail", "less", "more", "bat", "nl":
            guard let file = plain.last(where: { Int($0) == nil }) else { return nil }
            return "Reading \(name(file))"
        case "sed":
            // `sed -n` prints lines; anything else changes them.
            guard let file = plain.last, plain.count >= 2 else { return nil }
            return args.contains("-i") ? "Editing \(name(file))" : "Reading \(name(file))"
        case "grep", "rg", "ag", "egrep":
            guard let pattern = plain.first(where: { Int($0) == nil }) else { return nil }
            return "Searching for “\(clip(pattern))”"
        case "ls":
            return plain.last.map { "Listing \(name($0))" } ?? "Listing files"
        case "find", "fd":
            return "Finding files"
        case "git":
            switch plain.first {
            case "status": return "Checking git status"
            case "log": return "Reading git history"
            case "diff": return "Reviewing changes"
            case "show": return "Reading a commit"
            case "blame": return plain.last.map { "Reading the history of \(name($0))" }
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func name(_ path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty || last == "." ? "the folder" : last
    }

    private static func clip(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    /// Splits on spaces, keeping quoted text together and dropping the
    /// quotes. Unquoted |, ; and & come out as tokens of their own.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false
        func finish() {
            if started { result.append(current) }
            current = ""
            started = false
        }
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\\" {
                escaped = true
                started = true
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character == "|" || character == ";" || character == "&" {
                // Join a run like && or || into one token.
                if let last = result.last, !started, last.allSatisfy({ $0 == character }), last.count == 1 {
                    result[result.count - 1].append(character)
                } else {
                    finish()
                    result.append(String(character))
                }
            } else if character.isWhitespace {
                finish()
            } else {
                current.append(character)
                started = true
            }
        }
        finish()
        return result
    }
}
