import Foundation

/// What a shell command Claude ran amounts to, for the chat: a look at
/// some files, a file written in one go, or something else to show as a
/// command card.
public enum ShellStep {
    /// A command that only reads, searches or lists, worded for a quiet
    /// row: "Read PostView.swift · lines 195–205".
    public struct Read: Equatable, Sendable {
        public var symbol: String
        /// "Reading", "Searching for".
        public var verbNow: String
        /// "Read", "Searched for".
        public var verbThen: String
        /// The file, pattern or folder, shown in mono.
        public var target: String?
        /// A note after the target, like "lines 195–205".
        public var note: String?
        /// The file to open, when the command names one we can find.
        public var path: String?
    }

    /// A file written by a here-document: `cat > Banner.swift <<'EOF'`.
    public struct Write: Equatable, Sendable {
        public var path: String
        public var content: String
        /// True for `>>` or `tee -a`, which add to the end of the file.
        public var appends: Bool
    }

    // MARK: - Leading cd

    /// The command without a leading `cd somewhere &&`, which Claude adds
    /// to most commands and which says nothing about what it does.
    public static func withoutCD(_ command: String) -> String {
        var rest = Substring(command)
        while let match = rest.firstMatch(of: #/^\s*cd\s+("[^"]*"|'[^']*'|[^\s;&|]+)\s*(&&|;)\s*/#) {
            rest = rest[match.range.upperBound...]
        }
        return String(rest)
    }

    // MARK: - Reads

    /// How a read-only command reads, or nil for anything that could change
    /// something, or that isn't simple enough to be sure about.
    public static func read(_ command: String) -> Read? {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 1, var line = lines.first.map(String.init) else { return nil }
        // Quieting output or merging it isn't writing anything.
        line = line.replacing(#/\s*(\d|&)?>>?\s*\/dev\/null/#, with: "")
            .replacing(#/\s*2>&1/#, with: "")
        let chain = commands(line)
        guard !chain.isEmpty else { return nil }

        var directory: String?
        var main: [Word]?
        for pipeline in chain {
            guard let first = pipeline.first, !first.isEmpty else { return nil }
            if pipeline.count == 1, first.first?.text == "cd" {
                guard first.count == 2 else { return nil }
                directory = resolve(first[1].text, in: directory)
                continue
            }
            for stage in pipeline {
                guard isReadOnly(stage) else { return nil }
            }
            if main == nil { main = first }
        }
        guard let main else { return nil }
        return describe(main.map(\.text), directory: directory) ?? Read(
            symbol: "terminal", verbNow: "Running", verbThen: "Ran",
            target: clip(withoutCD(line), 60))
    }

    private static let readers: Set<String> = [
        "cat", "head", "tail", "nl", "wc", "less", "more", "bat", "sort", "uniq", "cut", "tr", "column",
        "jq", "xxd", "hexdump", "od", "file", "stat", "du", "df", "pwd", "which", "type", "whereis",
        "echo", "printf", "true", "basename", "dirname", "realpath", "readlink", "tree", "ls", "find",
        "fd", "rg", "grep", "egrep", "fgrep", "ag", "ack", "sed", "awk", "diff", "cmp", "comm",
        "plutil", "defaults", "git", "date", "uname", "sw_vers", "mdls", "otool", "nm", "strings",
        "lipo", "shasum", "md5", "sips",
    ]

    private static func isReadOnly(_ stage: [Word]) -> Bool {
        guard let program = stage.first.map({ ($0.text as NSString).lastPathComponent }),
              readers.contains(program) else { return false }
        // Any redirect left (after /dev/null) writes a file.
        if stage.contains(where: { !$0.quoted && ($0.text.contains(">") || $0.text.contains("<")) }) { return false }
        let args = stage.dropFirst().map(\.text)
        switch program {
        case "sed":
            return !args.contains { $0.hasPrefix("-i") || $0 == "--in-place" || $0.hasPrefix("--in-place=") }
        case "awk":
            return !args.contains { $0 == "-i" || $0.hasPrefix("inplace") }
        case "find":
            return !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls"].contains($0) }
        case "fd":
            return !args.contains { $0 == "-x" || $0 == "-X" || $0 == "--exec" || $0 == "--exec-batch" }
        case "plutil":
            return args.contains("-p") || args.contains("-lint")
        case "defaults":
            return args.first == "read" || args.first == "domains"
        case "sips":
            return args.first == "-g" || args.first == "--getProperty"
        case "sort":
            return !args.contains { $0 == "-o" || $0.hasPrefix("--output") }
        case "git":
            let plain = args.filter { !$0.hasPrefix("-") }
            switch plain.first {
            case "status", "log", "diff", "show", "blame", "rev-parse", "ls-files", "grep", "describe",
                 "shortlog", "rev-list", "cat-file", "ls-tree", "merge-base":
                return true
            case "branch":
                return plain.count == 1 && !args.contains { ["-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move"].contains($0) }
            case "remote":
                return plain.count == 1
            default:
                return false
            }
        default:
            return true
        }
    }

    private static func describe(_ words: [String], directory: String?) -> Read? {
        let program = (words[0] as NSString).lastPathComponent
        let args = Array(words.dropFirst())
        func file(_ path: String) -> (name: String, path: String?) {
            let last = (path as NSString).lastPathComponent
            return (last.isEmpty || last == "." ? "the folder" : last, resolve(path, in: directory))
        }
        func reading(_ path: String, note: String? = nil) -> Read {
            let f = file(path)
            return Read(symbol: "doc.text", verbNow: "Reading", verbThen: "Read", target: f.name, note: note, path: f.path)
        }
        switch program {
        case "cat", "nl", "bat", "less", "more":
            let files = operands(args, valued: ["-r", "--line-range"])
            guard let first = files.first else { return nil }
            let note = files.count > 1 ? "and \(files.count - 1) more" : nil
            return reading(first, note: note)
        case "head", "tail":
            let files = operands(args, valued: ["-n", "-c"])
            guard let first = files.last else { return nil }
            var note: String?
            if let count = value(of: "-n", in: args) ?? args.first(where: { $0.firstMatch(of: #/^-\d+$/#) != nil }).map({ String($0.dropFirst()) }) {
                note = program == "head" ? "first \(count) lines" : "last \(count) lines"
            }
            return reading(first, note: note)
        case "sed":
            let rest = operands(args, valued: ["-e", "-f"])
            guard rest.count >= 2, let path = rest.last else { return nil }
            let script = value(of: "-e", in: args) ?? rest[0]
            return reading(path, note: lineRange(script))
        case "awk":
            let rest = operands(args, valued: ["-F", "-v", "-f"])
            guard rest.count >= 2, let path = rest.last else { return nil }
            return reading(path)
        case "wc":
            guard let path = operands(args, valued: []).last else { return nil }
            let f = file(path)
            return Read(symbol: "number", verbNow: "Counting lines in", verbThen: "Counted lines in", target: f.name, path: f.path)
        case "grep", "egrep", "fgrep", "rg", "ag", "ack":
            let valued: Set<String> = ["-A", "-B", "-C", "-m", "-e", "-f", "-g", "-t", "-T", "--glob", "--type",
                                       "--include", "--exclude", "--max-count", "--context", "-M", "--max-columns"]
            let rest = operands(args, valued: valued)
            guard let pattern = value(of: "-e", in: args) ?? rest.first else { return nil }
            let place = (value(of: "-e", in: args) == nil ? rest.dropFirst() : rest[...]).first
            return Read(symbol: "magnifyingglass", verbNow: "Searching for", verbThen: "Searched for",
                        target: "“\(clip(pattern, 40))”", note: place.map { "in \(file($0).name)" })
        case "ls", "tree":
            let place = operands(args, valued: ["-L", "-I"]).last
            return Read(symbol: "folder", verbNow: "Listing", verbThen: "Listed", target: place.map { file($0).name } ?? "files")
        case "find", "fd":
            let name = value(of: "-name", in: args) ?? value(of: "-iname", in: args)
            return Read(symbol: "magnifyingglass", verbNow: "Finding", verbThen: "Found",
                        target: name.map { "“\(clip($0, 40))”" } ?? "files")
        case "git":
            let plain = args.filter { !$0.hasPrefix("-") }
            let wording: (String, String, String)? = switch plain.first {
            case "status": ("Checking", "Checked", "git status")
            case "log", "shortlog", "rev-list", "reflog": ("Reading", "Read", "git history")
            case "diff": ("Reviewing", "Reviewed", "changes")
            case "show": ("Reading", "Read", "a commit")
            case "blame": ("Reading", "Read", "the history of \(plain.last.map { file($0).name } ?? "a file")")
            case "grep": ("Searching", "Searched", "the repo")
            case "branch": ("Listing", "Listed", "branches")
            default: nil
            }
            guard let wording else { return nil }
            return Read(symbol: "arrow.triangle.branch", verbNow: wording.0, verbThen: wording.1, target: nil, note: wording.2)
        case "plutil", "jq", "stat", "file", "mdls", "xxd", "hexdump", "otool", "strings":
            guard let path = operands(args, valued: []).last else { return nil }
            return reading(path)
        default:
            return nil
        }
    }

    /// "195,205p" reads as "lines 195–205".
    private static func lineRange(_ script: String) -> String? {
        if let m = script.firstMatch(of: #/^(\d+),(\d+)p$/#) { return "lines \(m.1)–\(m.2)" }
        if let m = script.firstMatch(of: #/^(\d+)p$/#) { return "line \(m.1)" }
        if let m = script.firstMatch(of: #/^(\d+),\$p$/#) { return "from line \(m.1)" }
        return nil
    }

    /// The arguments that aren't options or option values.
    private static func operands(_ args: [String], valued: Set<String>) -> [String] {
        var result: [String] = []
        var skip = false
        var options = true
        for arg in args {
            if skip { skip = false; continue }
            if options, arg == "--" { options = false; continue }
            if options, arg.hasPrefix("-"), arg.count > 1 {
                if valued.contains(arg) { skip = true }
                continue
            }
            result.append(arg)
        }
        return result
    }

    private static func value(of option: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: option), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - Writes

    /// A file written whole by a here-document, the way Claude writes one
    /// when it uses the shell instead of its Write tool. Nil for anything
    /// else, or when the command does more than write the file.
    public static func write(_ command: String) -> Write? {
        var lines = command.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        let first = lines.removeFirst()
        let chain = commands(first)
        var directory: String?
        for (index, pipeline) in chain.enumerated() {
            guard pipeline.count == 1, let words = pipeline.first?.map(\.text), !words.isEmpty else { return nil }
            if words[0] == "cd", words.count == 2 {
                directory = resolve(words[1], in: directory)
                continue
            }
            // The here-document has to be the last thing on the line.
            guard index == chain.count - 1 else { return nil }
            return heredoc(words, body: lines, directory: directory)
        }
        return nil
    }

    private static func heredoc(_ words: [String], body: [String], directory: String?) -> Write? {
        let program = words[0]
        guard program == "cat" || program == "tee" else { return nil }
        var target: String?
        var appends = false
        var tag: String?
        var stripsTabs = false
        var index = 1
        while index < words.count {
            let word = words[index]
            func next() -> String? { index + 1 < words.count ? words[index + 1] : nil }
            if word.hasPrefix("<<") {
                var rest = word.dropFirst(2)
                if rest.hasPrefix("-") { stripsTabs = true; rest = rest.dropFirst() }
                if rest.isEmpty { tag = next(); index += 1 } else { tag = String(rest) }
            } else if program == "cat", word == ">" || word == ">>" {
                appends = word == ">>"
                target = next()
                index += 1
            } else if program == "cat", word.hasPrefix(">>") {
                appends = true
                target = String(word.dropFirst(2))
            } else if program == "cat", word.hasPrefix(">") {
                target = String(word.dropFirst())
            } else if program == "tee", word == "-a" {
                appends = true
            } else if program == "tee", !word.hasPrefix("-"), target == nil {
                target = word
            } else if program == "tee", word == ">" || word.hasPrefix(">") {
                // `tee file > /dev/null` was trimmed already, or writes elsewhere.
                return nil
            } else {
                return nil
            }
            index += 1
        }
        guard let target, !target.isEmpty, target != "/dev/null", let tag, !tag.isEmpty else { return nil }
        guard let end = body.firstIndex(where: { (stripsTabs ? $0.drop { $0 == "\t" } : Substring($0)) == tag }) else { return nil }
        // Nothing after the end marker but blank lines.
        guard body[(end + 1)...].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        var content = Array(body[..<end])
        if stripsTabs { content = content.map { String($0.drop { $0 == "\t" }) } }
        return Write(path: resolve(target, in: directory) ?? target, content: content.joined(separator: "\n") + "\n", appends: appends)
    }

    // MARK: - Pieces

    struct Word: Equatable {
        var text: String
        var quoted: Bool
    }

    /// The line as commands joined by &&, || and ;, each a pipeline of
    /// stages, each stage its words.
    static func commands(_ line: String) -> [[[Word]]] {
        var chain: [[[Word]]] = [[[]]]
        for word in words(line) {
            if !word.quoted, ["&&", "||", ";"].contains(word.text) {
                chain.append([[]])
            } else if !word.quoted, word.text == "|" {
                chain[chain.count - 1].append([])
            } else if !word.quoted, word.text == "&" {
                return []  // runs in the background: not a simple read
            } else {
                chain[chain.count - 1][chain[chain.count - 1].count - 1].append(word)
            }
        }
        return chain.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// Like `ShellWording.tokens`, but remembering which words were quoted,
    /// so a `>` in an awk script isn't taken for a redirect.
    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var current = ""
        var started = false
        var quoted = false
        var quote: Character?
        var escaped = false
        func finish() {
            if started { result.append(Word(text: current, quoted: quoted)) }
            current = ""
            started = false
            quoted = false
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
                quoted = true
            } else if character == "|" || character == ";" || character == "&" {
                if let last = result.last, !started, !last.quoted, last.text.count == 1, last.text.first == character {
                    result[result.count - 1].text.append(character)
                } else {
                    finish()
                    result.append(Word(text: String(character), quoted: false))
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

    /// An absolute path for `path`, or nil when there's nothing to anchor a
    /// relative one to.
    private static func resolve(_ path: String, in directory: String?) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        guard let directory else { return nil }
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
