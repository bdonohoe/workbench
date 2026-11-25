import BenchKit
import Foundation

/// What a terminal tab runs when it starts.
enum TabKind: String, Codable, CaseIterable {
    case shell
    /// A tab that runs a coding agent. Saved as "claude", which is what
    /// it was called when Claude Code was the only one.
    case agent = "claude"
    case diff
    case preview
    case file
    case review

    var defaultTitle: String {
        switch self {
        case .shell: "Shell"
        case .agent: Agents.standard.name
        case .diff: "Diff"
        case .preview: "Browser"
        case .file: "File"
        case .review: "Review"
        }
    }

    var symbol: String {
        switch self {
        case .shell: "terminal"
        case .agent: Agents.standard.symbol
        case .diff: "plus.forwardslash.minus"
        case .preview: "globe"
        case .file: "doc.text"
        case .review: "checklist"
        }
    }
}

/// A saved terminal tab. The shell itself is never saved; on relaunch a fresh
/// one starts in the project's folder.
struct TabRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: TabKind
    /// For an agent tab: which agent it runs. Nil for every other kind.
    var agent: AgentID?
    var title: String
    /// A first message for Claude when the tab opens. Saved until Claude
    /// has started with it, so quitting before then doesn't lose it.
    var initialPrompt: String?
    /// A past Claude session to pick back up when the tab opens. Saved
    /// until Claude has started; after that, the tab's own session record
    /// takes over.
    var resumeSessionID: String?
    /// A command a shell tab runs, like "bun run dev". Saved so the tab can
    /// be recognized later.
    var command: String?
    /// True only for a tab created this session, so the command doesn't
    /// run again when Bench relaunches.
    var runsCommandOnStart = false
    /// The changed file a diff tab shows.
    var diff: FileChange?
    /// Where a browser tab started: a local dev server, one of Claude's
    /// published pages, or nothing for a tab you opened empty. Its Home
    /// button comes back here.
    var previewURL: URL?
    /// Where a browser tab's page is now, after any links followed, so a
    /// relaunch comes back to it.
    var pageURL: URL?
    /// The file a file tab shows, relative to the project folder.
    var filePath: String?
    /// For a Claude tab: shown as a conversation instead of its terminal.
    /// The terminal keeps running underneath either way.
    var showsChat: Bool?
    /// For a Claude or shell tab: the Claude account it started with, so it
    /// keeps using it (and can resume its conversation) even if the project
    /// switches accounts later. nil for tabs from before accounts, which
    /// use the main one.
    var claudeAccountID: UUID?
    /// For a Codex or shell tab: the Codex account it started with, for the
    /// same reason. nil for tabs from before Codex accounts: the main one.
    var codexAccountID: UUID?
    /// A diff tab opened by a single click in the changes list: the next
    /// one replaces it, so reading through a change set doesn't leave a tab
    /// per file. Not saved; every tab is kept after a relaunch.
    var isPreview = false
    /// What a review tab shows: one commit, or the branch's whole change set.
    var review: ReviewTarget?
    /// A name you gave the tab. nil shows its own, like "Claude" or the
    /// command it runs.
    var customTitle: String?

    /// What the tab bar calls the tab.
    var displayTitle: String { customTitle ?? title }

    init(kind: TabKind, agent: AgentID? = nil, initialPrompt: String? = nil, command: String? = nil) {
        self.kind = kind
        let provider = kind == .agent ? Agents.provider(agent ?? Agents.standard.id) ?? Agents.standard : nil
        self.agent = provider?.id
        self.title = command ?? provider?.name ?? kind.defaultTitle
        self.initialPrompt = initialPrompt
        self.command = command
        runsCommandOnStart = command != nil
    }

    init(diff: FileChange) {
        kind = .diff
        title = diff.fileName
        self.diff = diff
    }

    init(previewURL: URL) {
        kind = .preview
        title = BrowserAddress.display(previewURL)
        self.previewURL = previewURL
    }

    /// A browser tab with no page yet, or one off on its own address with
    /// no home to come back to.
    init(browsing url: URL?) {
        kind = .preview
        title = url.map(BrowserAddress.display) ?? Self.emptyBrowserTitle
        pageURL = url
    }

    /// What an empty browser tab is called until it loads something.
    static let emptyBrowserTitle = "New Tab"

    init(filePath: String) {
        kind = .file
        title = (filePath as NSString).lastPathComponent
        self.filePath = filePath
    }

    init(review: ReviewTarget) {
        kind = .review
        title = review.title
        self.review = review
    }

    var isTerminal: Bool { kind == .shell || kind == .agent }
    /// Can be one side of a split: a terminal, or a web page beside one.
    var canSplit: Bool { isTerminal || kind == .preview }

    /// The agent this tab runs, if it's an agent tab.
    var provider: (any AgentProvider)? { agent.flatMap(Agents.provider) }
    /// The SF Symbol for the tab: its agent's, or its kind's.
    var symbol: String { provider?.symbol ?? kind.symbol }

    private enum CodingKeys: String, CodingKey {
        case id, kind, agent, title, diff, previewURL, pageURL, command, filePath, showsChat, initialPrompt, resumeSessionID, claudeAccountID, codexAccountID, review, customTitle
    }

    /// How an agent tab's kind is saved when its agent isn't Claude. A
    /// version of Workbench from before other agents doesn't know this
    /// kind, so it leaves the tab out instead of starting Claude in it.
    private static let otherAgentKind = "agent"

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        let savedKind = try values.decode(String.self, forKey: .kind)
        if savedKind == Self.otherAgentKind {
            kind = .agent
            let saved = try values.decode(AgentID.self, forKey: .agent)
            // An agent this version doesn't have: leave the tab out.
            guard Agents.provider(saved) != nil else {
                throw DecodingError.dataCorruptedError(forKey: .agent, in: values, debugDescription: "No agent called \(saved.rawValue)")
            }
            agent = saved
        } else if let known = TabKind(rawValue: savedKind) {
            kind = known
            agent = known == .agent ? .claude : nil
        } else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "No tab kind called \(savedKind)")
        }
        title = try values.decode(String.self, forKey: .title)
        diff = try values.decodeIfPresent(FileChange.self, forKey: .diff)
        previewURL = try values.decodeIfPresent(URL.self, forKey: .previewURL)
        pageURL = try values.decodeIfPresent(URL.self, forKey: .pageURL)
        command = try values.decodeIfPresent(String.self, forKey: .command)
        filePath = try values.decodeIfPresent(String.self, forKey: .filePath)
        showsChat = try values.decodeIfPresent(Bool.self, forKey: .showsChat)
        initialPrompt = try values.decodeIfPresent(String.self, forKey: .initialPrompt)
        resumeSessionID = try values.decodeIfPresent(String.self, forKey: .resumeSessionID)
        claudeAccountID = try values.decodeIfPresent(UUID.self, forKey: .claudeAccountID)
        codexAccountID = try values.decodeIfPresent(UUID.self, forKey: .codexAccountID)
        review = try values.decodeIfPresent(ReviewTarget.self, forKey: .review)
        customTitle = try values.decodeIfPresent(String.self, forKey: .customTitle)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        // A Claude tab is saved exactly as it always was.
        if kind == .agent, let agent, agent != .claude {
            try values.encode(Self.otherAgentKind, forKey: .kind)
            try values.encode(agent, forKey: .agent)
        } else {
            try values.encode(kind, forKey: .kind)
        }
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(diff, forKey: .diff)
        try values.encodeIfPresent(previewURL, forKey: .previewURL)
        try values.encodeIfPresent(pageURL, forKey: .pageURL)
        try values.encodeIfPresent(command, forKey: .command)
        try values.encodeIfPresent(filePath, forKey: .filePath)
        try values.encodeIfPresent(showsChat, forKey: .showsChat)
        try values.encodeIfPresent(initialPrompt, forKey: .initialPrompt)
        try values.encodeIfPresent(resumeSessionID, forKey: .resumeSessionID)
        try values.encodeIfPresent(claudeAccountID, forKey: .claudeAccountID)
        try values.encodeIfPresent(codexAccountID, forKey: .codexAccountID)
        try values.encodeIfPresent(review, forKey: .review)
        try values.encodeIfPresent(customTitle, forKey: .customTitle)
    }
}

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// A tab this build can't read (a kind from a newer build) is dropped
    /// on its own, so the project and its other tabs survive.
    @LossyArray var tabs: [TabRecord] = []
    var selectedTabID: UUID?
    /// Branch or ref the changes panel compares against. nil means auto-detect.
    var baseRef: String?

    /// For an agent's worktree: the project it branched from. nil for a
    /// regular project.
    var parentID: UUID?
    /// For a worktree: the branch it was created on.
    var branch: String?
    /// For a worktree: the parent project's name, for titles like
    /// "Bench · feat/menu-bar".
    var parentName: String?
    /// For a worktree: found in git rather than made by New Agent, so it's
    /// yours. Workbench lists it but never deletes it. nil for any worktree
    /// Workbench made, including ones saved before this existed.
    var madeOutsideWorkbench: Bool?
    /// A name you gave the project in the sidebar. nil shows the folder's.
    var customName: String?

    /// Worktree setup, set on a regular project: files copied into each new
    /// worktree (like .env), and a command run there (like bun install).
    var setupFiles: [String]?
    var setupCommand: String?

    /// Set on a regular project: worktrees you took out of the sidebar, so
    /// looking through git again doesn't bring them back.
    var hiddenWorktrees: [String]?

    /// The Claude account new Claude tabs here sign in with. nil is the
    /// main account, or for a worktree, whichever its project uses.
    var claudeAccountID: UUID?
    /// The Codex account new Codex tabs here sign in with, the same way.
    var codexAccountID: UUID?

    /// Pairs of tabs (terminals, or a page beside one) shown side by side or stacked. A tab is in
    /// at most one pair. nil when there are none.
    var splits: [TabSplit]?

    var url: URL { URL(fileURLWithPath: path) }
    var isWorktree: Bool { parentID != nil }
    var isExternalWorktree: Bool { isWorktree && madeOutsideWorkbench == true }
    var folderName: String { url.lastPathComponent }
    /// The name you gave it or the folder's, or "Parent · branch" for a
    /// worktree.
    var name: String {
        guard let parentName else { return customName ?? folderName }
        return "\(parentName) · \(branch ?? folderName)"
    }
    /// The project's own name, the same for a project and its worktrees.
    var repoName: String { parentName ?? customName ?? folderName }

    var selectedTab: TabRecord? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    // MARK: Splits

    /// The pair a tab is in, if any.
    func split(of tabID: UUID) -> TabSplit? {
        splits?.first { $0.first == tabID || $0.second == tabID }
    }

    /// The other tab in a tab's pair.
    func partner(of tabID: UUID) -> UUID? {
        split(of: tabID).map { $0.first == tabID ? $0.second : $0.first }
    }

    /// The tabs the tab bar shows as their own button, in order: a pair is
    /// one button, at its first tab's place.
    var tabStops: [TabRecord] {
        let seconds = Set((splits ?? []).map(\.second))
        return tabs.filter { !seconds.contains($0.id) }
    }

    /// Moves a tab bar button (a tab, or a pair by its first tab) to where
    /// `target`'s is, the way dragging it past that one does. A pair's
    /// second tab comes along right after its first.
    mutating func moveStop(_ id: UUID, over target: UUID) {
        var stops = tabStops.map(\.id)
        guard id != target, let from = stops.firstIndex(of: id), let to = stops.firstIndex(of: target) else { return }
        stops.insert(stops.remove(at: from), at: to)
        var ordered: [TabRecord] = []
        for stop in stops {
            guard let tab = tabs.first(where: { $0.id == stop }) else { continue }
            ordered.append(tab)
            if let split = split(of: stop), split.first == stop,
               let second = tabs.first(where: { $0.id == split.second }) {
                ordered.append(second)
            }
        }
        let placed = Set(ordered.map(\.id))
        ordered += tabs.filter { !placed.contains($0.id) }
        tabs = ordered
    }

    /// Drops pairs whose tabs were closed or can't be split, and any tab
    /// that ended up in two pairs.
    mutating func pruneSplits() {
        guard let current = splits else { return }
        let terminals = Set(tabs.filter(\.canSplit).map(\.id))
        var used = Set<UUID>()
        let kept = current.filter { split in
            guard split.first != split.second, terminals.contains(split.first), terminals.contains(split.second),
                  !used.contains(split.first), !used.contains(split.second) else { return false }
            used.insert(split.first)
            used.insert(split.second)
            return true
        }
        if kept != current { splits = kept.isEmpty ? nil : kept }
    }
}

/// Two tabs shown at once, side by side or one above the other.
struct TabSplit: Codable, Hashable {
    enum Axis: String, Codable {
        /// `first` on the left.
        case sideBySide
        /// `first` on top.
        case stacked
    }

    var first: UUID
    var second: UUID
    var axis: Axis
    /// How much of the space `first` gets, from 0 to 1.
    var fraction: Double = 0.5

    static let fractionRange = 0.15...0.85
}

/// What a review tab reads through: one commit, or everything the branch
/// changed since it left its base.
struct ReviewTarget: Codable, Hashable {
    /// The commit's full hash, or nil for the whole branch.
    var commit: String?
    var title: String
    /// Set to read through what one turn of a Claude tab changed, rather
    /// than a commit or the branch.
    var turn: Turn?

    /// A turn of a Claude tab's conversation.
    struct Turn: Codable, Hashable {
        var tabID: UUID
        /// The message that started the turn, or nil for whichever turn
        /// is the latest, following along as Claude works.
        var turnID: String?
    }

    static func turn(_ turnID: String?, inTab tabID: UUID) -> ReviewTarget {
        ReviewTarget(commit: nil, title: turnID == nil ? "Latest Turn" : "Turn Changes", turn: Turn(tabID: tabID, turnID: turnID))
    }

    static func commit(_ commit: Commit) -> ReviewTarget {
        ReviewTarget(commit: commit.hash, title: commit.subject)
    }

    static func branch(_ name: String?) -> ReviewTarget {
        ReviewTarget(commit: nil, title: name.map { "Review \($0)" } ?? "Review Branch")
    }
}
