import AppKit
import SwiftUI

// MARK: - Settings > Accounts: Codex

/// The Codex accounts Workbench can start Codex tabs with, and a guided way
/// to add another. Shown on the Accounts page once Codex is turned on.
struct CodexAccountsGroup: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var signingIn: CodexProfile?
    @State private var renaming: CodexProfile?
    @State private var draftName = ""
    /// The accounts that were new when the page opened.
    @State private var found: [UUID] = []

    private var accounts: CodexAccounts { .shared }

    /// True when Codex is on, so its accounts belong on the page.
    static var isShown: Bool { Agents.isOffered(.codex) }
    /// True when there's a Codex account to pick between for each project.
    static var hasChoice: Bool { isShown && CodexAccounts.shared.hasSeveral }

    var body: some View {
        SettingsGroup(title: "Codex",
                      footer: "Each Codex account is its own CODEX_HOME folder, with its own sign-in and past sessions. Workbench also finds folders like ~/.codex-work, and CODEX_HOME in your shell profile.") {
            ForEach(Array(accounts.profiles.enumerated()), id: \.element.id) { index, profile in
                CodexAccountRow(profile: profile, index: index, isNew: found.contains(profile.id),
                                signIn: { signingIn = profile },
                                rename: {
                                    draftName = profile.name
                                    renaming = profile
                                })
            }
            HStack {
                Button("Add Account…") { adding = true }
                Spacer()
                if accounts.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Look Again") { accounts.scan() }
                        .help("Look for Codex folders on this Mac that are signed in")
                }
            }
        }
        .onAppear {
            accounts.start()
            found = accounts.newlyFound
            accounts.dismissFound()
        }
        .sheet(isPresented: $adding) {
            AddCodexAccountSheet { adding = false }
        }
        .sheet(item: $signingIn) { profile in
            CodexSignInSheet(account: profile) { signingIn = nil }
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
}

/// One Codex account: who it is, its plan, and how many projects use it.
private struct CodexAccountRow: View {
    @Environment(AppStore.self) private var store
    let profile: CodexProfile
    let index: Int
    let isNew: Bool
    let signIn: () -> Void
    let rename: () -> Void

    var body: some View {
        let status = CodexAccounts.shared.status(of: profile.id)
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
                    NSWorkspace.shared.activateFileViewerSelecting([profile.home])
                }
                if !profile.isMain {
                    Button("Copy Terminal Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(profile.shellPrefix + "codex", forType: .string)
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
            .accessibilityLabel("\(profile.name) Codex account actions")
            .help(profile.isMain ? "Rename or sign in again" : "Rename, sign in again, or remove. Removing leaves the folder and sign-in in place.")
        }
    }

    private func confirmRemove() {
        let count = store.projects(usingCodexAccount: profile.id).count
        let alert = NSAlert()
        alert.messageText = "Remove \(profile.name) from Workbench?"
        let projects = count == 0 ? "" : count == 1 ? "The project that uses it goes back to your main Codex account. "
            : "The \(count) projects that use it go back to your main Codex account. "
        alert.informativeText = projects + "Its folder and sign-in stay on this Mac."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CodexAccounts.shared.remove(profile.id)
    }

    /// "you@example.com · Plus plan · 3 projects · ~/.codex-work"
    private func detail(_ status: ClaudeAccount.Status?) -> String {
        var parts: [String] = []
        if let status {
            if status.loggedIn, let email = status.email { parts.append(email) }
            parts.append(status.summary)
        } else {
            parts.append("Checking…")
        }
        if CodexAccounts.shared.hasSeveral {
            let count = store.projects(usingCodexAccount: profile.id).count
            parts.append(count == 1 ? "1 project" : "\(count) projects")
        }
        parts.append(profile.displayFolder)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Signing in

/// A small terminal running `codex login` for one account, which closes
/// once the sign-in lands.
struct CodexSignInSheet: View {
    let account: CodexProfile
    let done: () -> Void
    @State private var terminal: SignInTerminal?
    @State private var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Sign in to \(account.isMain ? "Codex" : account.name)",
                        detail: "Codex opens your browser to sign in. If your browser is signed in to a different ChatGPT account, switch to the right one there first. Workbench notices when you're done.")
            Group {
                if let terminal { SignInTerminalView(terminal: terminal) } else { Color.clear }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            HStack {
                if signedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Status.done)
                        .fontWeight(.semibold)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(signedIn ? "Done" : "Cancel", action: close)
                    .keyboardShortcut(signedIn ? .defaultAction : .cancelAction)
            }
        }
        .padding(22)
        .frame(width: 640)
        .task {
            if terminal == nil { terminal = SignInTerminal(command: CodexAccounts.loginCommand(account)) }
            let before = CodexAccounts.shared.status(of: account.id)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let profile = account
                let status = await Task.detached { CodexAccounts.readStatus(profile) }.value
                // A fresh sign-in, not the one that was there before.
                if let status, status.loggedIn, status != before || before?.loggedIn != true {
                    CodexAccounts.shared.refresh(account.id)
                    withAnimation { signedIn = true }
                    try? await Task.sleep(for: .seconds(1))
                    close()
                    return
                }
            }
        }
        .onDisappear { terminal?.close() }
    }

    private func close() {
        terminal?.close()
        CodexAccounts.shared.refresh(account.id)
        done()
    }
}

/// Three steps, as for a Claude account: name it, sign in, pick projects.
struct AddCodexAccountSheet: View {
    @Environment(AppStore.self) private var store
    let done: () -> Void

    private enum Step { case name, signIn, projects }
    @State private var step = Step.name
    @State private var name = ""
    @State private var shares = true
    @State private var folder: String?
    @State private var terminal: SignInTerminal?
    @State private var signedIn: ClaudeAccount.Status?
    @State private var profile: CodexProfile?
    @State private var chosen: Set<UUID> = []
    @State private var problem: String?

    private var accounts: CodexAccounts { .shared }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

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
            SheetHeader(title: "Add a Codex Account",
                        detail: "Use a second ChatGPT account with Codex for some of your projects, like a work account for work projects. Each account has its own sign-in, plan, and past sessions.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.ui(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Work", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(next)
            }
            Toggle(isOn: $shares) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share my Codex setup with it")
                    Text("Your config.toml, AGENTS.md, prompts, skills, and rules are linked in from \(CodexProfile.main().displayFolder), so a change to one shows up in both.")
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Text("Workbench keeps it in \(CodexProfile(id: UUID(), name: "", folder: CodexAccounts.newFolder(for: trimmedName)).displayFolder), where Codex in your own terminal can use it too.")
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

    private func next() {
        guard !trimmedName.isEmpty else { return }
        let folder = CodexAccounts.newFolder(for: trimmedName)
        do {
            try CodexAccounts.makeFolder(folder, sharing: shares)
        } catch {
            problem = "Workbench couldn't make \(folder): \(error.localizedDescription)"
            return
        }
        self.folder = folder
        let profile = CodexProfile(id: UUID(), name: trimmedName, folder: folder, madeByWorkbench: true)
        self.profile = profile
        terminal = SignInTerminal(command: CodexAccounts.loginCommand(profile))
        problem = nil
        withAnimation { step = .signIn }
    }

    // MARK: 2. Sign in

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Sign in to \(trimmedName)",
                        detail: "Codex opens your browser. Sign in with the account you want for \(trimmedName). If your browser is already signed in to your other ChatGPT account, switch accounts there first.")
            Group {
                if let terminal { SignInTerminalView(terminal: terminal) } else { Color.clear }
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
                    Button("Continue", action: finishSignIn)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task(id: terminal.map(ObjectIdentifier.init)) { await watch() }
    }

    /// Another account already signed in as the same person.
    private var sameAsExisting: CodexProfile? {
        guard let email = signedIn?.email else { return nil }
        return accounts.profiles.first { accounts.status(of: $0.id)?.email == email }
    }

    private func watch() async {
        guard let profile else { return }
        while !Task.isCancelled, signedIn == nil {
            try? await Task.sleep(for: .seconds(3))
            let status = await Task.detached { CodexAccounts.readStatus(profile) }.value
            if let status, status.loggedIn {
                withAnimation { signedIn = status }
            }
        }
    }

    private func retry() {
        terminal?.close()
        signedIn = nil
        if let profile { terminal = SignInTerminal(command: CodexAccounts.loginCommand(profile, signingOutFirst: true)) }
    }

    private func finishSignIn() {
        guard let folder else { return }
        terminal?.close()
        profile = accounts.add(name: trimmedName, folder: folder, madeByWorkbench: true)
        if let id = store.selectedProjectID.map(store.rootID(of:)) { chosen = [id] }
        withAnimation { step = .projects }
    }

    // MARK: 3. Projects

    private var projectsStep: some View {
        let projects = store.topLevelProjects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Which projects use \(trimmedName)?",
                        detail: "New Codex tabs in these projects sign in as \(signedIn?.email ?? trimmedName). The rest keep using the account they have now.")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(projects) { project in
                        Toggle(isOn: Binding(get: { chosen.contains(project.id) },
                                             set: { if $0 { chosen.insert(project.id) } else { chosen.remove(project.id) } })) {
                            HStack {
                                Text(project.name)
                                let current = store.codexAccountID(for: project.id)
                                if current != CodexProfile.mainID {
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
                    Text(profile.shellPrefix + "codex")
                        .font(.ui(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            HStack {
                Text("Change this any time on the Accounts page, or from a project's menu in the sidebar.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    if let profile {
                        for id in chosen { store.setCodexAccount(profile.id, for: id) }
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Leaving before the account is kept takes away the folder this sheet
    /// made, signing it out first so no stray sign-in is left behind.
    private func cancel() {
        terminal?.close()
        if step != .projects, let folder, !accounts.profiles.contains(where: { $0.folder == folder }) {
            let signedOut = signedIn != nil
            let profile = CodexProfile(id: UUID(), name: "", folder: folder)
            Task.detached {
                if signedOut { CodexAccounts.signOut(profile) }
                try? FileManager.default.removeItem(atPath: folder)
            }
        }
        done()
    }
}
