import AppKit
import BenchKit
import CoreGraphics
import Observation
import Sparkle
import SwiftUI

/// Keeps Bench up to date with Sparkle. Updates download in the
/// background, then install when you quit, when you choose Restart to
/// Update, or when the Mac has been left alone with nothing running.
/// Restarting closes every terminal, so it never happens out from under
/// Claude.
@Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    /// The version that's downloaded and waiting for a restart.
    private(set) var readyVersion: String?
    /// Its build number and release notes (HTML), from the feed.
    private(set) var readyBuild: Int?
    private(set) var readyNotes: String?
    /// False for development builds, which shouldn't replace themselves.
    let isEnabled: Bool

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private weak var terminals: TerminalManager?

    /// How long the Mac has to sit untouched, with nothing running, before
    /// an update installs by itself. Mostly for Macs nobody sits at.
    static let unattendedInstallDelay: TimeInterval = 30 * 60

    init(terminals: TerminalManager) {
        self.terminals = terminals
        #if DEBUG
        isEnabled = false
        #else
        // A second copy (make install-beta) would be replaced by the
        // release build if it followed the feed, so it never checks. Nor
        // does a copy someone else built from the source (OfficialBuild).
        isEnabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && !BenchPaths.isSecondaryInstance
            && OfficialBuild.isOfficial
        #endif
        super.init()
        if isEnabled {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
        #if DEBUG
        // Shows the sidebar button as if this version were downloaded.
        // "0.4:5" is version 0.4, build 5.
        if let fake = ProcessInfo.processInfo.environment["BENCH_FAKE_UPDATE"]?.split(separator: ":") {
            readyVersion = String(fake[0])
            readyBuild = fake.count > 1 ? Int(fake[1]) : nil
        }
        #endif
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Installs the waiting update and reopens Bench, after asking if
    /// Claude is in the middle of something.
    func restartToUpdate() {
        guard let installNow else { return }
        if let terminals, case let kept = terminals.tabsKeptThroughQuit(), terminals.quitInterruptsWork(keeping: kept) {
            let busy = terminals.busyTabNames(skipping: kept)
            let alert = NSAlert()
            alert.messageText = "Restart to update Workbench?"
            alert.informativeText = AppDelegate.interruptionText(busy, action: "Restarting")
            alert.addButton(withTitle: "Restart Now")
            if !busy.claude.isEmpty { alert.addButton(withTitle: "Restart When Agents Are Done") }
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn where !busy.claude.isEmpty:
                restartWhenIdle()
                return
            default: return
            }
        }
        restartsWhenIdle = false
        AppDelegate.skipsQuitConfirmation = true
        installNow()
    }

    /// Waiting to restart until Claude finishes in every tab.
    private(set) var restartsWhenIdle = false
    @ObservationIgnored private var idleWatch: Timer?

    /// Installs the update the moment no Claude tab is working or waiting
    /// on you. Programs in shells, like dev servers, don't hold it up.
    func restartWhenIdle() {
        restartsWhenIdle = true
        idleWatch?.invalidate()
        idleWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfClaudeIsDone() }
        }
    }

    private func restartIfClaudeIsDone() {
        guard restartsWhenIdle, let installNow else { cancelRestartWhenIdle(); return }
        guard terminals?.anyClaudeBusyForQuit == false else { return }
        cancelRestartWhenIdle()
        AppDelegate.skipsQuitConfirmation = true
        installNow()
    }

    func cancelRestartWhenIdle() {
        restartsWhenIdle = false
        idleWatch?.invalidate()
        idleWatch = nil
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        let build = Int(item.versionString)
        let notes = item.itemDescription
        // Sparkle calls this on the main thread.
        nonisolated(unsafe) let handler = immediateInstallHandler
        MainActor.assumeIsolated {
            readyVersion = version
            readyBuild = build
            readyNotes = notes
            installNow = handler
            watchForUnattended()
        }
        // We show our own Restart to Update button.
        return true
    }

    // MARK: Unattended Macs

    private func watchForUnattended() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfUnattended() }
        }
    }

    /// On unless you turn it off. It only ever acts when nothing would be
    /// interrupted, and someone who already turned it off stays off.
    static let installsWhenIdleKey = "installsUpdatesWhenIdle"
    static let installsWhenIdleByDefault = true

    private func installIfUnattended() {
        guard UserDefaults.standard.object(forKey: Self.installsWhenIdleKey) as? Bool ?? Self.installsWhenIdleByDefault,
              let installNow, let terminals,
              !terminals.quitInterruptsWork(keeping: terminals.tabsKeptThroughQuit()) else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle >= Self.unattendedInstallDelay else { return }
        AppDelegate.skipsQuitConfirmation = true
        installNow()
    }
}

/// "Check for Updates…" in the Bench menu, and Restart to Update once
/// one is ready.
struct UpdateCommands: Commands {
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("What's New in Workbench") { openWindow(id: "whats-new") }
            Button("Acknowledgements") { openWindow(id: "acknowledgements") }
            if updater.isEnabled {
                Button("Check for Updates…") { updater.checkForUpdates() }
                if let version = updater.readyVersion {
                    Button("Restart to Update to \(version)") { updater.restartToUpdate() }
                    if updater.restartsWhenIdle {
                        Button("Don't Restart When Agents Are Done") { updater.cancelRestartWhenIdle() }
                    }
                }
            }
        }
    }
}

/// A small button at the bottom of the sidebar while an update waits.
/// Clicking it shows what's new, with a button to restart.
struct UpdateReadyButton: View {
    @Environment(Updater.self) private var updater
    #if DEBUG
    @State private var showsNotes = ProcessInfo.processInfo.environment["BENCH_FAKE_UPDATE_OPEN"] != nil
    #else
    @State private var showsNotes = false
    #endif

    var body: some View {
        if let version = updater.readyVersion {
            Button {
                showsNotes.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Workbench \(version) is ready")
                            .font(.ui(size: 12, weight: .semibold))
                        Text(updater.restartsWhenIdle ? "Restarts when agents are done" : "See what's new")
                            .font(.ui(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.ui(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("See what's new in Workbench \(version), then restart to install it. It also installs when you quit.")
            .popover(isPresented: $showsNotes, arrowEdge: .top) {
                UpdateNotesPopover { showsNotes = false }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

