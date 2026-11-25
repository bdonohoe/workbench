import AppKit
import BenchKit
import SwiftUI

/// Installs an agent or signs in to it, in a small terminal inside
/// Workbench. It runs the same command you'd type yourself, shows it
/// first, and closes when the agent is ready.
struct AgentSetupSheet: View {
    enum Action: Equatable {
        case install, signIn
    }

    let agent: AgentSetup
    let action: Action
    /// Called when the sheet closes, finished or not.
    let done: () -> Void
    @State private var terminal: SignInTerminal?
    @State private var finished = false

    private var command: String { action == .install ? agent.installCommand : agent.signInCommand }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: action == .install ? "Install \(agent.product)" : "Sign in to \(agent.product)",
                detail: action == .install
                    ? "This runs \(agent.product)'s own installer, the same command you'd paste into a terminal. It may ask for your password. Workbench notices when it's done."
                    : "\(agent.product) opens your browser to sign in. If it asks how you want to sign in, choose with the arrow keys and press Return. Workbench notices when you're done.")
            CopyableCommand(command: command)
            Group {
                if let terminal {
                    SignInTerminalView(terminal: terminal)
                } else {
                    Color.clear
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            HStack {
                if finished {
                    Label(action == .install ? "Installed" : "Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.semibold)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.small)
                    Text(action == .install ? "Waiting for the install to finish…" : "Waiting for sign-in…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Done" : "Cancel", action: close)
                    .keyboardShortcut(finished ? .defaultAction : .cancelAction)
            }
        }
        .padding(22)
        .frame(width: 640)
        .task {
            if terminal == nil { terminal = SignInTerminal(command: command) }
            Analytics.capture(.agentSetupStarted, ["agent": agent.id.rawValue, "action": action == .install ? "install" : "sign_in"])
            await watch()
        }
        .onDisappear { terminal?.close() }
    }

    /// Checks every few seconds until the agent is installed (or, for
    /// signing in, ready).
    private func watch() async {
        let id = agent.id, wantsReady = action == .signIn
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            let state = await Task.detached { () -> AgentSetup.State in
                Tools.recheck()
                AgentPrograms.forget()
                return AgentSetup.state(of: id)
            }.value
            if wantsReady ? state.isReady : state != .notInstalled, !finished {
                Analytics.capture(.agentSetupCompleted, ["agent": id.rawValue, "action": wantsReady ? "sign_in" : "install"])
                withAnimation { finished = true }
                // Signing in closes by itself. An install stays, so you
                // can read what it printed.
                if wantsReady {
                    try? await Task.sleep(for: .seconds(1))
                    close()
                }
                return
            }
        }
    }

    private func close() {
        terminal?.close()
        done()
    }
}

/// A command shown to be read and copied.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.ui(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .controlSize(.small)
            .accessibilityLabel(copied ? "Copied" : "Copy the command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// The button beside an agent that isn't ready: install it, or sign in.
/// Opens the sheet, and checks again when it closes.
struct AgentSetupButton: View {
    let agent: AgentSetup
    let action: AgentSetupSheet.Action
    /// "Install" where the row already names the agent; nil spells it out.
    var title: String?
    @State private var isOpen = false

    var body: some View {
        Button(title ?? (action == .install ? "Install…" : "Sign In…")) { isOpen = true }
            .sheet(isPresented: $isOpen) {
                AgentSetupSheet(agent: agent, action: action) {
                    isOpen = false
                    Task { await SetupCheck.shared.run(rescan: true) }
                }
                .terminalSheet()
            }
    }
}
