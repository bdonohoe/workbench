import SwiftUI

struct ShortcutRow: View {
    let shortcut: TabShortcut
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: shortcut.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.name)
                Text(shortcut.command)
                    .font(.ui(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(shortcut.command)
            }
            Spacer()
            Button("Edit…", action: edit)
                .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

struct ShortcutEditor: View {
    @Environment(TabShortcuts.self) private var shortcuts
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var shortcut: TabShortcut
    let isNew: Bool

    private var canSave: Bool {
        !shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !shortcut.command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: isNew ? "New Shortcut" : "Edit Shortcut")
            Form {
                TextField("Name", text: $shortcut.name, prompt: Text("Mini"))
                TextField("Command", text: $shortcut.command, prompt: Text("ssh my-server"))
                    .font(.system(.body, design: .monospaced))
                Picker("Icon", selection: $shortcut.symbol) {
                    ForEach(TabShortcut.symbols, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).labelStyle(.iconOnly).tag(symbol)
                    }
                }
                Picker("Projects", selection: $shortcut.projectID) {
                    Text("All projects").tag(UUID?.none)
                    Divider()
                    ForEach(store.projects.filter { !$0.isWorktree }) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                TextField("Only when the project has", text: $shortcut.requiredFile, prompt: Text("Any file, like Makefile"))
                Toggle("Switch to its tab if it's still running", isOn: $shortcut.reusesRunningTab)
            }
            .formStyle(.columns)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        shortcuts.delete(shortcut.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    shortcut.name = shortcut.name.trimmingCharacters(in: .whitespaces)
                    shortcut.command = shortcut.command.trimmingCharacters(in: .whitespaces)
                    shortcuts.save(shortcut)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
        .terminalSheet()
    }
}

// MARK: - Claude actions

struct ClaudeActionRow: View {
    let action: ClaudeAction
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.name)
                Text(action.prompt)
                    .font(.ui(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(action.prompt)
            }
            Spacer()
            Button("Edit…", action: edit)
                .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

/// Edits one Claude action: its label, the message it sends, and its icon.
/// The built-in ones keep their role (what greys the button out), and new
/// ones are always available.
struct ClaudeActionEditor: View {
    @Environment(ClaudeActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State var action: ClaudeAction
    let isNew: Bool

    private var canSave: Bool {
        !action.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: isNew ? "New Action" : "Edit Action",
                        detail: "Write {branch} and {base} to put in the branch names, and {pr} for the pull request's number.")
            Form {
                TextField("Name", text: $action.name, prompt: Text("Rebase"))
                Picker("Icon", selection: $action.symbol) {
                    ForEach(ClaudeAction.symbols, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).labelStyle(.iconOnly).tag(symbol)
                    }
                }
                LabeledContent("Message") {
                    TextEditor(text: $action.prompt)
                        .font(.ui(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 120)
                        .background(TerminalTheme.shared.sheetField, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                }
            }
            .formStyle(.columns)
            HStack {
                if !isNew {
                    Button("Delete…", role: .destructive) { confirmDelete() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    action.name = action.name.trimmingCharacters(in: .whitespaces)
                    action.prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    actions.save(action)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .terminalSheet()
    }

    /// Asks first: the message is something you wrote, and it goes with it.
    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(action.name)\u{201D}?"
        alert.informativeText = "The action and its message are deleted."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actions.delete(action.id)
        dismiss()
    }
}
