import AppKit
import BenchKit
import SwiftUI

/// A small terminal running `claude auth login`, for when Claude Code is
/// installed but not signed in. Watches for the sign-in to land and closes
/// itself when it does.
struct ClaudeSignInSheet: View {
    /// "welcome", "settings", or "accounts", for analytics.
    let from: String
    /// The account to sign in to: the main one unless it says otherwise.
    var account: ClaudeProfile = .main()
    /// Called when the sheet closes, signed in or not.
    let done: () -> Void
    @State private var terminal: SignInTerminal?
    @State private var signedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: account.isMain ? "Sign in to Claude Code" : "Sign in to \(account.name)",
                detail: account.isMain
                    ? "Claude Code opens your browser to sign in. If it asks how you want to sign in, choose with the arrow keys and press Return. Workbench notices when you're done."
                    : "Claude Code opens your browser to sign in. If your browser is signed in to a different Claude account, switch to the right one there first. Workbench notices when you're done.")
            Group {
                if let terminal {
                    SignInTerminalView(terminal: terminal)
                } else {
                    Color.clear
                }
            }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            HStack {
                if signedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.semibold)
                        .transition(.opacity)
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
            if terminal == nil { terminal = SignInTerminal(account: account) }
            Analytics.capture(.claudeSignInStarted, ["from": from])
            await watch()
        }
        .onDisappear { terminal?.close() }
    }

    /// Checks every few seconds until Claude Code reports an account.
    private func watch() async {
        guard let claude = Tools.path("claude") else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            let folder = account.folder
            let result = await Task.detached {
                folder == nil ? SetupCheck.claudeSignedIn(claude) : ClaudeAccount.read(claude: claude, folder: folder)?.loggedIn
            }.value
            if result == true, !signedIn {
                Analytics.capture(.claudeSignInCompleted, ["from": from])
                withAnimation { signedIn = true }
                try? await Task.sleep(for: .seconds(1))
                close()
                return
            }
        }
    }

    private func close() {
        terminal?.close()
        ClaudeAccounts.shared.account(for: account.id).checkNow()
        done()
    }
}

/// Owns the terminal so it lives as long as the sheet.
@MainActor
final class SignInTerminal {
    let view: TerminalSurfaceView

    /// With `signingOutFirst`, signs out of whatever account the folder has
    /// before signing in, for trying again with a different one.
    init(account: ClaudeProfile = .main(), signingOutFirst: Bool = false) {
        let claude = Tools.path("claude").map(ClaudeProfile.quote) ?? "claude"
        var launch = TerminalSurfaceView.Launch(workingDirectory: NSHomeDirectory())
        let prefix = account.shellPrefix
        launch.initialInput = (signingOutFirst ? "\(prefix)\(claude) auth logout; " : "") + "\(prefix)\(claude) auth login\n"
        view = TerminalSurfaceView(launch: launch)
    }

    /// A terminal that runs one command, typed in as you would.
    init(command: String) {
        var launch = TerminalSurfaceView.Launch(workingDirectory: NSHomeDirectory())
        launch.initialInput = command + "\n"
        view = TerminalSurfaceView(launch: launch)
    }

    func close() { view.close() }
}

struct SignInTerminalView: NSViewRepresentable {
    let terminal: SignInTerminal

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.wantsLayer = true
        container.layer?.backgroundColor = TerminalTheme.shared.background?.cgColor
        let view = terminal.view
        container.addSubview(view)
        view.setOccluded(false)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return container
    }

    func updateNSView(_ container: Container, context: Context) {}

    /// Keeps the terminal a little inside its background once there's room.
    final class Container: NSView {
        override func layout() {
            super.layout()
            guard bounds.width > 12, bounds.height > 12 else { return }
            subviews.first?.frame = bounds.insetBy(dx: 6, dy: 6)
        }
    }
}
