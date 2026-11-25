import BenchKit
import SwiftUI

/// The Mac's menu commands, for an iPad with a keyboard: they show in the
/// menu bar and in the list you get by holding Command.
struct PhoneCommands: Commands {
    let client: CompanionClient
    let navigator: Navigator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent Tab") {
                if let project = navigator.selected { client.newClaudeTab(projectID: project, prompt: nil) }
            }
            .keyboardShortcut("t")
            .disabled(navigator.selected == nil)
            Button("New Agent on a Branch…") {
                if let project = navigator.selected { navigator.push(NewAgentRoute(projectID: project)) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(navigator.selected == nil)
            Button("Brain Dump…") { navigator.showsSendTasks = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!client.canSendTasks)
        }
        CommandGroup(after: .sidebar) {
            Button("Next Session Needing You") { jumpToNextNeedingYou() }
                .keyboardShortcut("j")
            Button("Past Sessions") {
                if let project = navigator.selected { navigator.push(PastSessionsRoute(projectID: project)) }
            }
            .keyboardShortcut("y")
            .disabled(navigator.selected == nil)
            Divider()
            // Always nine items, as on the Mac: SwiftUI doesn't add menu
            // items when a list grows after launch.
            ForEach(0..<9, id: \.self) { index in
                Button(projects.indices.contains(index) ? projects[index].name : "Project \(index + 1)") {
                    if projects.indices.contains(index) { navigator.select(projects[index].id) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                .disabled(!projects.indices.contains(index))
            }
        }
    }

    /// Projects in the sidebar's order: pinned, then the rest of Active.
    /// Inactive ones are left out, as on the Mac.
    private var projects: [CompanionProject] {
        let top = client.snapshot?.topLevel ?? []
        guard top.contains(where: { $0.isActive != nil }) else { return Array(top.prefix(9)) }
        let pinned = top.filter { $0.isPinned == true }
        let active = top.filter { $0.isActive == true && $0.isPinned != true }
        return Array((pinned + active).prefix(9))
    }

    /// Goes to the next project waiting on you, then ones that need
    /// attention or finished, starting after the one that's open, so
    /// pressing it again walks the list.
    private func jumpToNextNeedingYou() {
        let all = client.snapshot?.projects ?? []
        let order: [ActivityKind] = [.waiting, .attention, .done]
        let queue: [CompanionProject] = order.flatMap { activity in all.filter { $0.activity == activity } }
        guard !queue.isEmpty else { return }
        var next = queue[0]
        if let current = queue.firstIndex(where: { $0.id == navigator.selected }) {
            next = queue[(current + 1) % queue.count]
        }
        navigator.select(next.id)
    }
}
