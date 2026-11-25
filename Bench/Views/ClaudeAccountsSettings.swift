import AppKit
import SwiftUI

// MARK: - Settings > Accounts

/// The accounts Workbench can start each agent with, which projects use
/// each, and a guided way to add another. Claude Code's come first, then
/// Codex's once it's turned on (`CodexAccountsGroup`).
struct ClaudeAccountsSettings: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var signingIn: ClaudeProfile?
    @State private var renaming: ClaudeProfile?
    @State private var draftName = ""
    /// The accounts that were new when the page opened, so they stay marked
    /// while you look even though they're no longer "new".
    @State private var found: [UUID] = []

    private var accounts: ClaudeAccounts { .shared }

    var body: some View {
        if !found.isEmpty {
            FoundNote(count: found.count)
        }
        SettingsGroup(title: "Claude Code",
                      footer: "Each account has its own sign-in, plan limits, and past conversations. Projects use your main account unless you pick another, and agents on a branch use their project's account.") {
            ForEach(Array(accounts.profiles.enumerated()), id: \.element.id) { index, profile in
                AccountRow(profile: profile, index: index, isNew: found.contains(profile.id),
                           signIn: { signingIn = profile },
                           rename: {
                               draftName = profile.name
                               renaming = profile
                           })
            }
            HStack {
                Button("Add Account…") { adding = true }
                Spacer()
            }
        }
        if CodexAccountsGroup.isShown {
            CodexAccountsGroup()
        }
        if accounts.hasSeveral || CodexAccountsGroup.hasChoice {
            ProjectAccounts()
        }
        SettingsGroup(title: "Already Use Another Claude Account?",
                      footer: "Workbench looks for folders like ~/.claude-work, and for CLAUDE_CONFIG_DIR in your shell profile, each time it opens. Signed-in ones are added here for you.") {
            SettingsRow(title: "Look for accounts on this Mac",
                        detail: "For an account you set up in Terminal with CLAUDE_CONFIG_DIR.") {
                if accounts.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Look Again") { accounts.scan() }
                }
            }
            SettingsRow(title: "Add a folder yourself",
                        detail: "Pick the folder CLAUDE_CONFIG_DIR points to, if Workbench didn't find it.") {
                Button("Choose Folder…", action: chooseFolder)
            }
        }
        .onAppear {
            found = accounts.newlyFound
            accounts.dismissFound()
            if store.addsClaudeAccount {
                store.addsClaudeAccount = false
                adding = true
            }
        }
        .onChange(of: store.addsClaudeAccount) { _, on in
            if on {
                store.addsClaudeAccount = false
                adding = true
            }
        }
        .sheet(isPresented: $adding) {
            AddAccountSheet { adding = false }
        }
        .sheet(item: $signingIn) { profile in
            ClaudeSignInSheet(from: "accounts", account: profile) { signingIn = nil }
                .terminalSheet()
        }
        .alert("Rename Account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let renaming { accounts.rename(renaming.id, to: draftName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// For a folder Workbench didn't find: it must be signed in to count.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Choose the folder CLAUDE_CONFIG_DIR is set to"
        panel.prompt = "Add Account"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.path
        if folder == ClaudeProfile.main().configURL.path { return }
        let profile = accounts.add(name: ClaudeAccounts.name(forFolder: folder), folder: folder, madeByWorkbench: false)
        accounts.account(for: profile.id).checkNow()
        Analytics.capture(.claudeAccountAdded, ["how": "folder"])
    }
}

/// "Workbench found 2 accounts", the first time you look after it does.
private struct FoundNote: View {
    let count: Int

    var body: some View {
        InfoBanner(symbol: "sparkle.magnifyingglass",
                   text: count == 1
                       ? "Workbench found another Claude account on this Mac. Pick which projects use it below."
                       : "Workbench found \(count) more Claude accounts on this Mac. Pick which projects use them below.")
    }
}

/// One account: who it is, how it pays, and how many projects use it.
private struct AccountRow: View {
    @Environment(AppStore.self) private var store
    let profile: ClaudeProfile
    let index: Int
    let isNew: Bool
    let signIn: () -> Void
    let rename: () -> Void

    var body: some View {
        let account = ClaudeAccounts.shared.account(for: profile.id)
        let status = account.status
        HStack(spacing: 12) {
            AccountBadge(name: profile.name, index: index, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.ui(size: 13, weight: .medium))
                    if profile.isMain {
                        Chip("Main")
                    }
                    if isNew {
                        Chip("Found", tint: Theme.accent)
                    }
                }
                Text(detail(status))
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail(status))
            }
            Spacer(minLength: 12)
            if status?.loggedIn == false {
                Button("Sign In", action: signIn)
            }
            Menu {
                Button("Rename…", action: rename)
                Button(status?.loggedIn == true ? "Sign In Again…" : "Sign In…", action: signIn)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([profile.configURL])
                }
                if !profile.isMain {
                    Button("Copy Terminal Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(profile.shellPrefix + "claude", forType: .string)
                    }
                    Divider()
                    Button("Remove from Workbench…", role: .destructive) { confirmRemove() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Names the account, since each row has one of these buttons.
            .accessibilityLabel("\(profile.name) account actions")
            .help(profile.isMain ? "Rename or sign in again" : "Rename, sign in again, or remove. Removing leaves the folder and sign-in in place.")
        }
    }

    /// Asks first: the projects that use this account lose it.
    private func confirmRemove() {
        let count = store.projects(using: profile.id).count
        let alert = NSAlert()
        alert.messageText = "Remove \(profile.name) from Workbench?"
        let projects = count == 0 ? "" : count == 1 ? "The project that uses it goes back to your main account. "
            : "The \(count) projects that use it go back to your main account. "
        alert.informativeText = projects + "Its folder and sign-in stay on this Mac."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClaudeAccounts.shared.remove(profile.id)
    }

    /// "you@example.com · Max plan · 3 projects · ~/.claude-work"
    private func detail(_ status: ClaudeAccount.Status?) -> String {
        var parts: [String] = []
        if let status {
            if status.loggedIn, let email = status.email { parts.append(email) }
            parts.append(status.summary)
        } else {
            parts.append("Checking…")
        }
        let count = store.projects(using: profile.id).count
        if ClaudeAccounts.shared.hasSeveral {
            parts.append(count == 1 ? "1 project" : "\(count) projects")
        }
        parts.append(profile.displayFolder)
        return parts.joined(separator: " · ")
    }
}

/// Every project, with the account its new tabs use for each agent that
/// has more than one.
private struct ProjectAccounts: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let projects = store.topLevelProjects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let claude = ClaudeAccounts.shared.hasSeveral
        let codex = CodexAccountsGroup.hasChoice
        SettingsGroup(title: "Projects",
                      footer: "The account each project's new tabs sign in with. Tabs already open keep the account they started with. You can also switch from a project's menu in the sidebar, or the arrow next to + in the tab bar.") {
            ForEach(projects) { project in
                SettingsRow(title: project.name) {
                    HStack(spacing: 14) {
                        if claude {
                            AgentAccountPicker(agent: "Claude", showsAgent: codex, project: project.name,
                                               selection: Binding(get: { store.claudeAccountID(for: project.id) },
                                                                  set: { store.setClaudeAccount($0, for: project.id) }),
                                               choices: ClaudeAccounts.shared.profiles.map { ($0.id, $0.name) })
                        }
                        if codex {
                            AgentAccountPicker(agent: "Codex", showsAgent: claude, project: project.name,
                                               selection: Binding(get: { store.codexAccountID(for: project.id) },
                                                                  set: { store.setCodexAccount($0, for: project.id) }),
                                               choices: CodexAccounts.shared.profiles.map { ($0.id, $0.name) })
                        }
                    }
                }
            }
        }
    }
}

/// One agent's account for one project, named for its agent when there's
/// more than one picker in the row.
private struct AgentAccountPicker: View {
    let agent: String
    let showsAgent: Bool
    let project: String
    @Binding var selection: UUID
    let choices: [(id: UUID, name: String)]

    var body: some View {
        HStack(spacing: 6) {
            if showsAgent {
                Text(agent)
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
            }
            Picker("\(agent) account for \(project)", selection: $selection) {
                ForEach(choices, id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

// MARK: - A small mark for an account

/// The account's first letter in a colored circle, the same color
/// everywhere it shows up.
struct AccountBadge: View {
    let name: String
    let index: Int
    var size: CGFloat = 16

    static func color(_ index: Int) -> Color {
        let colors: [Color] = [.orange, .blue, .purple, .green, .pink, .teal, .indigo, .brown]
        return colors[index % colors.count]
    }

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(index).gradient))
            .accessibilityHidden(true)
    }
}

extension ClaudeAccounts {
    /// Where an account sits in the list, for its color.
    func index(of id: UUID) -> Int {
        profiles.firstIndex { $0.id == id } ?? 0
    }
}

// MARK: - Choosing a project's account

/// The accounts to pick from for a project, then ways to add or manage
/// them. Used in the sidebar's project menu and the tab bar's ＋ menu.
struct ProjectAccountMenuItems: View {
    @Environment(AppStore.self) private var store
    let projectID: UUID

    /// What a menu holding these is called: "Claude Account", or
    /// "Accounts" once Codex has accounts to pick from too.
    static var title: String { CodexAccountsGroup.hasChoice ? "Accounts" : "Claude Account" }
    /// True when a project has an account to pick for any agent.
    static var hasChoice: Bool { ClaudeAccounts.shared.hasSeveral || CodexAccountsGroup.hasChoice }

    var body: some View {
        if CodexAccountsGroup.hasChoice {
            Section("Claude Code") { claudeChoices }
            Section("Codex") { codexChoices }
        } else {
            claudeChoices
        }
        Divider()
        let accounts = ClaudeAccounts.shared
        Button(accounts.hasSeveral ? "Add Another Claude Account…" : "Use Another Claude Account…") {
            store.addsClaudeAccount = true
            store.settingsSection = .accounts
        }
        if accounts.hasSeveral || CodexAccountsGroup.hasChoice {
            Button("Manage Accounts…") { store.settingsSection = .accounts }
        }
    }

    @ViewBuilder private var claudeChoices: some View {
        let accounts = ClaudeAccounts.shared
        let current = store.claudeAccountID(for: projectID)
        ForEach(accounts.profiles) { profile in
            Toggle(isOn: Binding(get: { current == profile.id }, set: { if $0 { store.setClaudeAccount(profile.id, for: projectID) } })) {
                let email = accounts.account(for: profile.id).status?.email
                Text(email.map { "\(profile.name) (\($0))" } ?? profile.name)
            }
        }
    }

    @ViewBuilder private var codexChoices: some View {
        let accounts = CodexAccounts.shared
        let current = store.codexAccountID(for: projectID)
        ForEach(accounts.profiles) { profile in
            Toggle(isOn: Binding(get: { current == profile.id }, set: { if $0 { store.setCodexAccount(profile.id, for: projectID) } })) {
                let email = accounts.status(of: profile.id)?.email
                Text(email.map { "\(profile.name) (\($0))" } ?? profile.name)
            }
        }
    }
}

/// Once, after Workbench finds accounts made outside it: says so, and
/// points to where projects pick one.
struct AccountsFoundBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let accounts = ClaudeAccounts.shared
        let found = accounts.newlyFound.map { accounts.profile($0) }.filter { !$0.isMain }
        if !found.isEmpty {
            InfoBanner(symbol: "person.2.fill", text: message(found),
                       action: ("Choose Projects…", { store.settingsSection = .accounts }),
                       dismiss: { accounts.dismissFound() })
                .padding(.horizontal, TerminalCard.margin)
                .padding(.bottom, 6)
        }
    }

    private func message(_ found: [ClaudeProfile]) -> String {
        if found.count == 1 {
            let email = ClaudeAccounts.shared.account(for: found[0].id).status?.email
            let who = email.map { "\(found[0].name) (\($0))" } ?? found[0].name
            return "Workbench found your other Claude account, \(who). Each project can use whichever account you pick."
        }
        return "Workbench found \(found.count) more Claude accounts on this Mac. Each project can use whichever account you pick."
    }
}

// MARK: - Adding an account

/// Three steps: name it, sign in, pick projects.
struct AddAccountSheet: View {
    @Environment(AppStore.self) private var store
    let done: () -> Void

    private enum Step { case name, signIn, projects }
    @State private var step = Step.name
    @State private var name = ""
    @State private var shares = true
    @State private var folder: String?
    @State private var terminal: SignInTerminal?
    @State private var signedIn: ClaudeAccount.Status?
    @State private var profile: ClaudeProfile?
    @State private var chosen: Set<UUID> = []
    @State private var problem: String?

    private var accounts: ClaudeAccounts { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .name: nameStep
            case .signIn: signInStep
            case .projects: projectsStep
            }
        }
        .padding(22)
        .frame(width: 600)
        .terminalSheet()
        .onDisappear { terminal?.close() }
    }

    // MARK: 1. Name

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Add a Claude Account",
                        detail: "Use a second Claude account for some of your projects, like a work account for work projects. Each account has its own sign-in, plan limits, and past conversations.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.ui(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Work", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(next)
            }
            Toggle(isOn: $shares) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share my Claude Code setup with it")
                    Text("Your settings, CLAUDE.md, skills, commands, agents, and plugins are linked in from ~/.claude, so a change to one shows up in both.")
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Text("Workbench keeps it in \(ClaudeProfile(id: UUID(), name: "", folder: ClaudeAccounts.newFolder(for: trimmedName)).displayFolder), where Claude Code in your own terminal can use it too.")
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.ui(size: 12)).foregroundStyle(Theme.Status.failed)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: next)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func next() {
        guard !trimmedName.isEmpty else { return }
        let folder = ClaudeAccounts.newFolder(for: trimmedName)
        do {
            try ClaudeAccounts.makeFolder(folder, sharing: shares)
        } catch {
            problem = "Workbench couldn't make \(folder): \(error.localizedDescription)"
            return
        }
        self.folder = folder
        let profile = ClaudeProfile(id: UUID(), name: trimmedName, folder: folder, madeByWorkbench: true)
        self.profile = profile
        terminal = SignInTerminal(account: profile)
        problem = nil
        withAnimation { step = .signIn }
    }

    // MARK: 2. Sign in

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Sign in to \(trimmedName)",
                        detail: "Claude Code opens your browser. Sign in with the account you want for \(trimmedName). If your browser is already signed in to your other Claude account, switch accounts there first.")
            Group {
                if let terminal {
                    SignInTerminalView(terminal: terminal)
                } else {
                    Color.clear
                }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            if let same = sameAsExisting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("That's the same account as \(same.name). Sign out in your browser, then sign in again with the other account.")
                        .font(.ui(size: 12))
                        .foregroundStyle(Theme.Status.waiting)
                    Button("Sign In Again", action: retry)
                }
            }
            HStack {
                if let signedIn, sameAsExisting == nil {
                    Label("Signed in as \(signedIn.email ?? "your account")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Status.done)
                        .fontWeight(.semibold)
                } else if signedIn == nil {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                if signedIn != nil {
                    Button("Continue") { finishSignIn() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task(id: terminal.map(ObjectIdentifier.init)) { await watch() }
    }

    /// Another account already signed in as the same person.
    private var sameAsExisting: ClaudeProfile? {
        guard let email = signedIn?.email else { return nil }
        return accounts.profiles.first { accounts.account(for: $0.id).status?.email == email }
    }

    private func watch() async {
        guard let folder, let claude = Tools.path("claude") else { return }
        while !Task.isCancelled, signedIn == nil {
            try? await Task.sleep(for: .seconds(3))
            let status = await Task.detached { ClaudeAccount.read(claude: claude, folder: folder) }.value
            if let status, status.loggedIn {
                withAnimation { signedIn = status }
                Analytics.capture(.claudeSignInCompleted, ["from": "add_account"])
            }
        }
    }

    private func retry() {
        terminal?.close()
        signedIn = nil
        if let profile { terminal = SignInTerminal(account: profile, signingOutFirst: true) }
    }

    private func finishSignIn() {
        guard let folder else { return }
        terminal?.close()
        let added = accounts.add(name: trimmedName, folder: folder, madeByWorkbench: true)
        accounts.account(for: added.id).checkNow()
        profile = added
        Analytics.capture(.claudeAccountAdded, ["how": "sheet", "shares": shares])
        if let id = store.selectedProjectID.map(store.rootID(of:)) { chosen = [id] }
        withAnimation { step = .projects }
    }

    // MARK: 3. Projects

    private var projectsStep: some View {
        let projects = store.topLevelProjects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Which projects use \(trimmedName)?",
                        detail: "New Claude tabs in these projects sign in as \(signedIn?.email ?? trimmedName). The rest keep using the account they have now.")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(projects) { project in
                        Toggle(isOn: Binding(get: { chosen.contains(project.id) },
                                             set: { if $0 { chosen.insert(project.id) } else { chosen.remove(project.id) } })) {
                            HStack {
                                Text(project.name)
                                let current = store.claudeAccountID(for: project.id)
                                if current != ClaudeProfile.mainID {
                                    Text("uses \(accounts.profile(current).name)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            if let profile {
                VStack(alignment: .leading, spacing: 4) {
                    Text("To use it in your own terminal:")
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                    Text(profile.shellPrefix + "claude")
                        .font(.ui(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            HStack {
                Text("Change this any time from a project's menu in the sidebar.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    if let profile {
                        for id in chosen { store.setClaudeAccount(profile.id, for: id) }
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Shared

    /// Leaving before signing in takes away the folder this sheet made.
    private func cancel() {
        terminal?.close()
        if step != .projects, let folder, !accounts.profiles.contains(where: { $0.folder == folder }) {
            // Signed in but not kept: sign out, so no stray sign-in is left
            // in the Keychain, then take the folder away.
            let signedOut = signedIn != nil
            Task.detached {
                if signedOut, let claude = Tools.path("claude") {
                    _ = Tools.runInShell("CLAUDE_CONFIG_DIR=\(ClaudeProfile.quote(folder)) \(ClaudeProfile.quote(claude)) auth logout",
                                         requireSuccess: false)
                }
                try? FileManager.default.removeItem(atPath: folder)
            }
        }
        done()
    }
}
