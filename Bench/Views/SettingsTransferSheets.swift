import AppKit
import SwiftUI

/// Settings > General: export your setup to a file, or import one.
struct MoveSettingsGroup: View {
    @State private var showsExport = false
    @State private var importing: SettingsTransfer.Archive?
    @State private var problem: String?

    var body: some View {
        SettingsGroup(title: "Move to Another Mac",
                      footer: "Exports your setup to one file, in parts you choose. On the other Mac, import it and Workbench restarts with your setup. Claude sign-ins, the iPhone pairing, and your Ghostty font don't come along.") {
            SettingsRow(title: "Export Settings", detail: "Save your setup to a file.") {
                Button("Export…") { showsExport = true }
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsRow(title: "Import Settings", detail: "Replace parts of this Mac's setup with the ones in a file. What it replaces is backed up first.") {
                    Button("Import…", action: chooseFile)
                }
                // A line of its own, so a file that wouldn't open doesn't
                // pass for the row's description.
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(size: 12))
                        .foregroundStyle(Theme.Status.failed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $showsExport) { ExportSettingsSheet() }
        .sheet(item: Binding(get: { importing.map(ImportItem.init) }, set: { importing = $0?.archive })) { item in
            ImportSettingsSheet(archive: item.archive)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Workbench settings file"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importing = try SettingsTransfer.read(Data(contentsOf: url))
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private struct ImportItem: Identifiable {
        let archive: SettingsTransfer.Archive
        var id: Date { archive.exportedAt }
    }
}

/// Checkboxes for the parts of a setup, with what each one holds.
private struct SectionChoices: View {
    let sections: [SettingsTransfer.Section]
    @Binding var chosen: Set<SettingsTransfer.Section>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sections) { section in
                Toggle(isOn: Binding(get: { chosen.contains(section) },
                                     set: { if $0 { chosen.insert(section) } else { chosen.remove(section) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                        Text(section.detail)
                            .font(.ui(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

struct ExportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set(SettingsTransfer.Section.allCases.filter(\.isOnByDefault))
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Export Settings",
                        detail: "Choose what to bring to the other Mac. You can choose again when you import.")
            SectionChoices(sections: SettingsTransfer.Section.allCases, chosen: $chosen)
            if let problem {
                Text(problem).font(.ui(size: 12)).foregroundStyle(Theme.Status.failed)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .terminalSheet()
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Workbench Settings.json"
        panel.message = chosen.contains(.pairedMacs)
            ? "This file holds the keys to your paired Macs. Keep it private."
            : "Save your Workbench settings"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsTransfer.export(chosen).write(to: url, options: .atomic)
            dismiss()
        } catch {
            problem = "Workbench couldn't save the file: \(error.localizedDescription)"
        }
    }
}

struct ImportSettingsSheet: View {
    let archive: SettingsTransfer.Archive
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<SettingsTransfer.Section> = []
    @State private var problem: String?

    private var sections: [SettingsTransfer.Section] {
        SettingsTransfer.Section.allCases.filter { archive.sections[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Import Settings",
                        detail: "From \(archive.fromMac), exported \(archive.exportedAt.formatted(date: .abbreviated, time: .shortened)). What you choose replaces the same part of this Mac's setup.")
            SectionChoices(sections: sections, chosen: $chosen)
            if let missing = missingFoldersNote {
                Label(missing, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(size: 12))
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Workbench restarts to finish, and stops anything running in its tabs. What's replaced is backed up in Application Support, in Workbench's Backups folder.")
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.ui(size: 12)).foregroundStyle(Theme.Status.failed)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import and Restart", action: importAndRestart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .terminalSheet()
        .onAppear { chosen = Set(sections) }
    }

    private var missingFoldersNote: String? {
        guard chosen.contains(.projects) else { return nil }
        let (missing, total) = SettingsTransfer.missingProjectFolders(in: archive)
        guard missing > 0 else { return nil }
        let count = missing == total ? "None of the \(total) project folders are" : "\(missing) of \(total) project folders aren't"
        return "\(count) on this Mac yet. Those projects show as missing until their folders are at the same place as on \(archive.fromMac)."
    }

    private func importAndRestart() {
        do {
            try SettingsTransfer.stage(archive, sections: chosen)
        } catch {
            problem = "Workbench couldn't get the import ready: \(error.localizedDescription)"
            return
        }
        dismiss()
        Restart.now()
    }
}

/// Quits and opens Workbench again. A cancelled quit (Claude was busy and
/// you chose Cancel) leaves it running, and a staged import then waits for
/// the next launch.
enum Restart {
    static func now() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do { try helper.run() } catch {
            NSLog("Bench: couldn't set up the restart: \(error)")
        }
        NSApp.terminate(nil)
        // Still here, so the quit was cancelled.
        if helper.isRunning { helper.terminate() }
    }
}
