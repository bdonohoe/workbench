import BenchKit
import SwiftUI

/// Closing a Claude tab, or cleaning up or discarding an agent, on the
/// Mac. Each asks first with the same warnings the Mac uses.
enum AgentAction: Identifiable, Hashable {
    case closeSession(projectID: UUID, session: CompanionSession)
    case cleanUp(CompanionProject)
    case discard(CompanionProject)

    var id: String {
        switch self {
        case .closeSession(_, let session): "close-\(session.id)"
        case .cleanUp(let project): "clean-\(project.id)"
        case .discard(let project): "discard-\(project.id)"
        }
    }

    var title: String {
        switch self {
        case .closeSession(_, let session): "Close this \(session.agentTitle) tab?"
        case .cleanUp(let project): "Clean up \(project.branch ?? project.name)?"
        case .discard(let project): "Discard \(project.branch ?? project.name)?"
        }
    }

    var button: String {
        switch self {
        case .closeSession: "Close Tab"
        case .cleanUp: "Clean Up"
        case .discard: "Discard"
        }
    }

    var message: String {
        switch self {
        case .closeSession(_, let session):
            return session.activity == .idle
                ? "You can resume it later from Past Sessions."
                : "\(session.agentTitle) is still running in it. Closing the tab ends that session; you can resume it later from Past Sessions."
        case .cleanUp(let project):
            return "Its pull request is merged. The folder is removed from your Mac and its local branch is deleted." + Self.risk(project.cleanup)
        case .discard(let project):
            return "The agent's worktree folder is removed from your Mac and its local branch is deleted. Anything already pushed stays on GitHub." + Self.risk(project.cleanup)
        }
    }

    private static func risk(_ cleanup: CompanionCleanup?) -> String {
        switch cleanup {
        case .ready?: ""
        case .uncommitted?: " It has uncommitted changes, which will be lost."
        case .unpushed?: " It has commits that were never pushed, so they'll only be recoverable from git's reflog."
        case .unknown?: " Workbench couldn't check it for uncommitted changes or unpushed commits."
        case nil: " Any uncommitted changes will be lost."
        }
    }

    func run(_ client: CompanionClient) {
        switch self {
        case .closeSession(let projectID, let session): client.closeSession(projectID: projectID, sessionID: session.id)
        case .cleanUp(let project): client.removeAgent(projectID: project.id, discard: false)
        case .discard(let project): client.removeAgent(projectID: project.id, discard: true)
        }
    }
}

extension View {
    /// Asks before running `action`, then runs it, and shows the Mac's
    /// answer if it couldn't.
    func agentActionConfirmation(_ action: Binding<AgentAction?>) -> some View {
        modifier(AgentActionConfirmation(action: action))
    }
}

private struct AgentActionConfirmation: ViewModifier {
    @Environment(CompanionClient.self) private var client
    @Binding var action: AgentAction?
    /// The action sent last, while the Mac might still answer with a problem.
    @State private var sent: AgentAction?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(action?.title ?? "", isPresented: Binding(
                get: { action != nil },
                set: { if !$0 { action = nil } }
            ), titleVisibility: .visible, presenting: action) { pending in
                Button(pending.button, role: .destructive) {
                    sent = pending
                    pending.run(client)
                }
            } message: { pending in
                Text(pending.message)
            }
            .onChange(of: client.lastProblem) { _, problem in
                guard sent != nil, let problem else { return }
                sent = nil
                failure = problem
            }
            .alert("Couldn't do that on your Mac", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }
}

/// Clean Up and Discard for an agent, for its menus.
struct AgentRemovalButtons: View {
    @Environment(CompanionClient.self) private var client
    let project: CompanionProject
    @Binding var pending: AgentAction?

    var body: some View {
        if project.isWorktree, project.isExternalWorktree != true, client.canManageAgents {
            if project.cleanup != nil {
                Button("Clean Up", systemImage: "checkmark.circle") { pending = .cleanUp(project) }
            }
            Button("Discard Agent", systemImage: "trash", role: .destructive) { pending = .discard(project) }
        }
    }
}
