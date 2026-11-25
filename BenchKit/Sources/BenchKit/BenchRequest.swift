import Foundation

/// One run of the `bench` command line tool, as it reaches Workbench.
///
/// The tool doesn't interpret anything. It writes where it ran and the
/// arguments it was given, and Workbench decides what they mean, so the
/// app that's running is the only thing that has to know the commands.
///
/// The request is a few `key=value` header lines and a blank line, then
/// each argument followed by a zero byte (arguments can hold line
/// breaks), then whatever was on standard input when the tool was asked
/// to read it.
public struct BenchRequest: Equatable, Sendable {
    /// The tab the command ran in, when Workbench started that tab.
    public var tabID: UUID?
    /// The folder the command ran in.
    public var folder: String?
    public var arguments: [String]
    /// Standard input, once Workbench has asked for it. Nil the first
    /// time round: most commands never need it, and reading it when
    /// nothing is coming would hang.
    public var input: String?

    public init(tabID: UUID? = nil, folder: String? = nil, arguments: [String], input: String? = nil) {
        self.tabID = tabID
        self.folder = folder
        self.arguments = arguments
        self.input = input
    }

    public static func parse(_ body: String) -> BenchRequest {
        var request = BenchRequest(arguments: [])
        let split = body.range(of: "\n\n")
        let header = split.map { body[..<$0.lowerBound] } ?? body[...]
        var count = 0
        var hasInput = false
        for line in header.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equals)...])
            switch line[..<equals] {
            case "tab": request.tabID = UUID(uuidString: value)
            case "cwd": request.folder = value.isEmpty ? nil : value
            case "args": count = Int(value) ?? 0
            case "stdin": hasInput = value == "1"
            default: break
            }
        }
        guard let split else { return request }
        var rest = body[split.upperBound...]
        for _ in 0..<count {
            guard let end = rest.firstIndex(of: "\0") else { break }
            request.arguments.append(String(rest[..<end]))
            rest = rest[rest.index(after: end)...]
        }
        if hasInput { request.input = String(rest) }
        return request
    }

    /// The command's name, lowercased, or nil when none was given.
    public var commandName: String? { arguments.first?.lowercased() }
}

/// The arguments after the command's name, sorted into options and the rest.
public struct BenchArguments: Equatable, Sendable {
    public var positional: [String] = []
    public var values: [String: String] = [:]
    public var flags: Set<String> = []

    public struct Problem: Error, Equatable, Sendable {
        public var message: String
    }

    /// `--name value` and `--name=value` for the command's value options,
    /// `--name` for its flags. Everything after `--` is taken as written,
    /// and so is everything after the first plain word when `stopsAtFirstWord`
    /// is set, for commands whose last argument is a shell command.
    public init(_ arguments: [String], for command: BenchCommand, stopsAtFirstWord: Bool = false) throws(Problem) {
        var rest = arguments[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "--" {
                positional += rest
                break
            }
            guard argument.hasPrefix("--"), argument.count > 2 else {
                positional.append(argument)
                if stopsAtFirstWord {
                    positional += rest
                    break
                }
                continue
            }
            let body = argument.dropFirst(2)
            let equals = body.firstIndex(of: "=")
            let name = String(equals.map { body[..<$0] } ?? body)
            if command.valueOptions.contains(name) {
                if let equals {
                    values[name] = String(body[body.index(after: equals)...])
                } else if let value = rest.first {
                    values[name] = value
                    rest = rest.dropFirst()
                } else {
                    throw Problem(message: "--\(name) needs a value.")
                }
            } else if command.flags.contains(name), equals == nil {
                flags.insert(name)
            } else {
                let known = (command.valueOptions + command.flags).map { "--\($0)" }
                throw Problem(message: "`bench \(command.name)` has no option \(argument)."
                              + (known.isEmpty ? "" : " Its options: \(known.joined(separator: ", "))."))
            }
        }
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    /// The plain words joined back into one piece of text, or nil when
    /// there were none.
    public func text(from index: Int = 0) -> String? {
        let words = positional.dropFirst(index)
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// A project or agent as `bench` names it.
public struct BenchTarget: Equatable, Sendable {
    public var id: UUID
    /// The project's name in the sidebar.
    public var name: String
    /// An agent's branch, which is what it goes by.
    public var branch: String?
    public var path: String
    /// The project an agent belongs to. Nil for a project itself.
    public var parentID: UUID?
    public var tabIDs: [UUID]

    public init(id: UUID, name: String, branch: String? = nil, path: String, parentID: UUID? = nil, tabIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.branch = branch
        self.path = path
        self.parentID = parentID
        self.tabIDs = tabIDs
    }

    /// What to call it: an agent's branch, a project's name.
    public var label: String { parentID == nil ? name : branch ?? name }

    public enum Found: Equatable, Sendable {
        case one(BenchTarget)
        /// Nothing by that name. The names that would have worked.
        case unknown(String, choices: [String])
        /// Several things by that name, by folder.
        case ambiguous(String, folders: [String])
    }

    /// Where a command ran: the project whose tab ran it, else the
    /// deepest project holding the folder it ran in.
    public static func home(tabID: UUID?, folder: String?, among all: [BenchTarget]) -> BenchTarget? {
        if let tabID, let match = all.first(where: { $0.tabIDs.contains(tabID) }) { return match }
        guard let folder else { return nil }
        let here = standardized(folder)
        return all.map { (target: $0, path: standardized($0.path)) }
            .filter { here == $0.path || here.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }?.target
    }

    /// The top-level project a target belongs to.
    public static func root(of target: BenchTarget, among all: [BenchTarget]) -> BenchTarget {
        target.parentID.flatMap { id in all.first { $0.id == id } } ?? target
    }

    /// Finds what a name means, looking first among `home`'s own project
    /// and its agents, then across every project. A name can be an
    /// agent's branch, the last part of its branch, a project's name, or
    /// a folder.
    public static func find(_ name: String, home: BenchTarget?, among all: [BenchTarget]) -> Found {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        let path = standardized(wanted)
        if wanted.contains("/") || wanted.hasPrefix("~") || wanted == ".",
           let match = all.first(where: { standardized($0.path) == path }) {
            return .one(match)
        }
        let family: [BenchTarget] = home.map { home in
            let rootID = home.parentID ?? home.id
            return all.filter { $0.id == rootID || $0.parentID == rootID }
        } ?? []
        for group in [family, all] {
            for matches in [group.filter({ same($0.label, wanted) }),
                            group.filter({ $0.parentID != nil && same($0.name, wanted) }),
                            group.filter({ $0.branch.map { same(lastPart($0), wanted) } ?? false })] where !matches.isEmpty {
                return matches.count == 1 ? .one(matches[0]) : .ambiguous(wanted, folders: matches.map(\.path))
            }
        }
        let choices = (family.isEmpty ? all.filter { $0.parentID == nil } : family).map(\.label)
        return .unknown(wanted, choices: choices)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func lastPart(_ branch: String) -> String {
        branch.split(separator: "/").last.map(String.init) ?? branch
    }

    static func standardized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standard = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}
