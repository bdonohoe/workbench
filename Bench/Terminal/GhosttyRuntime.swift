import AppKit
import BenchKit
import GhosttyKit
import UserNotifications

/// Owns the single libghostty app instance and routes its callbacks to the
/// terminal views. Adapted from Ghostty's macOS app (MIT licensed).
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var startupError: String?
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        Self.scrubInheritedEnvironment()
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            startupError = "libghostty failed to initialize."
            return
        }

        guard let config = Self.loadConfig() else {
            startupError = "Could not load the Ghostty configuration."
            return
        }
        self.config = config
        TerminalTheme.shared.update(from: config)

        var runtime = Self.makeRuntimeConfig(userdata: Unmanaged.passUnretained(self).toOpaque())

        guard let app = ghostty_app_new(&runtime, config) else {
            startupError = "libghostty could not create an app instance."
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        Self.applyColorScheme(to: app)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated {
                guard let app = GhosttyRuntime.shared.app else { return }
                Self.applyColorScheme(to: app)
                // A built-in theme has a light and a dark version; reload to
                // swap them when the Mac's appearance changes.
                if TerminalTheme.shared.source == .builtIn { GhosttyRuntime.shared.reloadConfig() }
            }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) } }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) } }
        }
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) } }
        }
    }

    private static func applyColorScheme(to app: ghostty_app_t) {
        ghostty_app_set_color_scheme(app, NSApp.effectiveAppearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// The C callbacks libghostty calls. These must be nonisolated: some
    /// (like wakeup) arrive on libghostty's renderer and IO threads.
    nonisolated private static func makeRuntimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.tick() } }
            },
            action_cb: { app, target, action in
                // Reach the runtime through userdata, not `shared`: libghostty can
                // fire actions while `shared` is still being initialized.
                guard let app, let userdata = ghostty_app_userdata(app) else { return false }
                let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                return GhosttyRuntime.onMain(false, (action, target, runtime)) { $0.2.handle(action: $0.0, target: $0.1) }
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.onMain(GHOSTTY_CLIPBOARD_READ_UNSUPPORTED, (userdata, state, mimes)) {
                    GhosttyRuntime.readClipboard($0.0, location: location, state: $0.1, mimes: $0.2, mimesLen: mimesLen, list: list)
                }
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.onMain((), (userdata, confirm, state)) {
                    GhosttyRuntime.confirmReadClipboard($0.0, confirm: $0.1, state: $0.2, request: request)
                }
            },
            write_clipboard_cb: { _, location, content, len, _ in
                GhosttyRuntime.onMain((), content) {
                    GhosttyRuntime.writeClipboard(location: location, content: $0, len: len)
                }
            },
            close_surface_cb: { userdata, _ in
                guard let userdata else { return }
                let address = UInt(bitPattern: userdata)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // The view may have been dropped (and its surface
                        // freed) in the meantime; only a live one is told.
                        guard let pointer = UnsafeMutableRawPointer(bitPattern: address),
                              let view = TerminalSurfaceView.view(forUserdata: pointer) else { return }
                        view.delegate?.terminalDidClose(view)
                    }
                }
            }
        )
    }

    /// When Bench is launched from another terminal (or a Claude session), that
    /// terminal's variables leak into every shell Bench starts. Drop them so
    /// Bench's shells look like fresh logins.
    private static func scrubInheritedEnvironment() {
        let prefixes = ["CLAUDE_CODE_", "GHOSTTY_", "ITERM_", "VSCODE_", "TERM_SESSION_"]
        let exact: Set<String> = ["CLAUDECODE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM", "COLORTERM", "OLDPWD"]
        for key in ProcessInfo.processInfo.environment.keys
        where exact.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) {
            unsetenv(key)
        }
    }

    /// Loads the user's own Ghostty config so Bench matches their font and theme.
    private static func loadConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        // Bench's own defaults load first, so the user's config can override them.
        if let defaults = writeBenchDefaults() {
            ghostty_config_load_file(config, defaults.path)
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        turnOffSSHIntegration(config)
        // A built-in theme goes on top of the user's config, so its colors
        // win over their Ghostty theme while everything else (font, keys)
        // stays theirs.
        if let theme = TerminalTheme.shared.activeBuiltInTheme(dark: NSApp.effectiveAppearance.isDark),
           let url = writeBuiltInTheme(theme) {
            ghostty_config_load_file(config, url.path)
        }
        #if DEBUG
        // Test copies can layer an extra config on top, to try other themes.
        if let extra = ProcessInfo.processInfo.environment["BENCH_TEST_GHOSTTY_CONFIG"] {
            ghostty_config_load_file(config, extra)
        }
        #endif
        ghostty_config_finalize(config)
        let count = ghostty_config_diagnostics_count(config)
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, i)
            if let message = diag.message { NSLog("Bench: Ghostty config: \(String(cString: message))") }
        }
        return config
    }

    /// Ghostty's `ssh-env` and `ssh-terminfo` shell-integration features
    /// wrap `ssh` in a shell function that runs `ghostty +ssh`. Bench has no
    /// `ghostty` program, so with either one on in the user's Ghostty config
    /// every `ssh` in a Bench terminal failed (including remote project tabs).
    /// Turn just those two off and keep the rest of the user's choices.
    private static func turnOffSSHIntegration(_ config: ghostty_config_t) {
        var bits: UInt32 = 0
        let key = "shell-integration-features"
        guard ghostty_config_get(config, &bits, key, UInt(key.utf8.count)),
              let line = shellFeaturesWithoutSSH(bits) else { return }
        let url = BenchPaths.support.appendingPathComponent("ghostty-no-ssh.conf")
        do {
            try FileManager.default.createDirectory(at: BenchPaths.support, withIntermediateDirectories: true)
            try line.write(to: url, atomically: true, encoding: .utf8)
            ghostty_config_load_file(config, url.path)
        } catch {
            NSLog("Bench: couldn't turn off Ghostty's ssh integration: \(error)")
        }
    }

    /// The fields of Ghostty's `ShellIntegrationFeatures`, in bit order.
    static let shellFeatureNames = ["cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "path"]

    /// A config line that sets every feature as `bits` has it, with the ssh
    /// ones off. Ghostty resets unnamed features to their defaults when it
    /// reads this setting, so every one is spelled out. Nil when neither
    /// ssh feature is on.
    static func shellFeaturesWithoutSSH(_ bits: UInt32) -> String? {
        let ssh: Set = ["ssh-env", "ssh-terminfo"]
        let on = { (index: Int) in bits & (1 << UInt32(index)) != 0 }
        guard shellFeatureNames.indices.contains(where: { on($0) && ssh.contains(shellFeatureNames[$0]) }) else { return nil }
        let parts = shellFeatureNames.enumerated().map { index, name in
            on(index) && !ssh.contains(name) ? name : "no-" + name
        }
        return "shell-integration-features = " + parts.joined(separator: ",") + "\n"
    }

    /// Key bindings Ghostty doesn't have out of the box. Ghostty already maps
    /// Cmd+Backspace to "delete to line start"; these add "delete previous
    /// word" (Ctrl+W) on Option+Backspace and Ctrl+Backspace.
    private static let benchDefaults = """
        keybind = alt+backspace=text:\\x17
        keybind = ctrl+backspace=text:\\x17

        """

    /// Ghostty only loads config from files, so the defaults go in one.
    private static func writeBenchDefaults() -> URL? {
        let url = BenchPaths.support.appendingPathComponent("ghostty-defaults.conf")
        do {
            try FileManager.default.createDirectory(at: BenchPaths.support, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != benchDefaults {
                try benchDefaults.write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        } catch {
            NSLog("Bench: couldn't write Ghostty defaults: \(error)")
            return nil
        }
    }

    /// The chosen built-in theme, as a Ghostty config file.
    private static func writeBuiltInTheme(_ theme: BuiltInTheme) -> URL? {
        let url = BenchPaths.support.appendingPathComponent("builtin-theme.conf")
        do {
            try FileManager.default.createDirectory(at: BenchPaths.support, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != theme.ghosttyConfig {
                try theme.ghosttyConfig.write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        } catch {
            NSLog("Bench: couldn't write the built-in theme: \(error)")
            return nil
        }
    }

    /// Reads the config files again and hands them to every terminal, as
    /// Ghostty's own "reload config" does. Used when the theme choice
    /// changes.
    func reloadConfig() {
        guard let app, let fresh = Self.loadConfig() else { return }
        ghostty_app_update_config(app, fresh)
        TerminalTheme.shared.update(from: fresh)
        if let old = config { ghostty_config_free(old) }
        config = fresh
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Runs `body` if we're on the main thread. libghostty delivers these
    /// callbacks on the main thread in practice; anything else is dropped.
    nonisolated private static func onMain<T: Sendable, Args>(
        _ fallback: T, _ args: Args, _ body: @MainActor (Args) -> T
    ) -> T {
        guard Thread.isMainThread else {
            NSLog("Bench: dropped a libghostty callback that arrived off the main thread")
            return fallback
        }
        // The C pointers in args are only touched here, on the main thread.
        let box = UncheckedSendable(args)
        return MainActor.assumeIsolated { body(box.value) }
    }

    // MARK: Actions

    private func surfaceView(_ target: ghostty_target_s) -> TerminalSurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return nil }
        return TerminalSurfaceView.view(forUserdata: userdata)
    }

    private func handle(action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        let view = surfaceView(target)

        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // A "soft" reload re-applies the current config, e.g. after the
            // light/dark setting changes and a conditional theme should switch.
            // A full reload re-reads the config files from disk.
            guard let app else { return false }
            if action.action.reload_config.soft {
                guard let config else { return false }
                if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                    ghostty_surface_update_config(surface, config)
                } else {
                    ghostty_app_update_config(app, config)
                }
            } else {
                reloadConfig()
            }

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let ptr = action.action.set_title.title else { return false }
            view.delegate?.terminal(view, didSetTitle: String(cString: ptr))

        case GHOSTTY_ACTION_PWD:
            guard let view, let ptr = action.action.pwd.pwd else { return false }
            view.delegate?.terminal(view, didChangeDirectory: String(cString: ptr))

        case GHOSTTY_ACTION_RING_BELL:
            guard let view else { return false }
            view.delegate?.terminalDidRingBell(view)

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // Claude Code sends these when it finishes or needs input.
            guard let view else { return false }
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            view.delegate?.terminal(view, didNotify: title, body: body)

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let view else { return false }
            let active = action.action.progress_report.state != GHOSTTY_PROGRESS_STATE_REMOVE
            view.delegate?.terminal(view, didReportProgress: active)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursorShape(action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            switch action.action.mouse_visibility {
            case GHOSTTY_MOUSE_VISIBLE: NSCursor.setHiddenUntilMouseMoves(false)
            default: NSCursor.setHiddenUntilMouseMoves(true)
            }

        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            view?.cellSize = NSSize(width: Double(size.width), height: Double(size.height))

        case GHOSTTY_ACTION_OPEN_URL:
            let open = action.action.open_url
            guard let ptr = open.url else { return false }
            let data = Data(bytes: ptr, count: Int(open.len))
            guard let string = String(data: data, encoding: .utf8) else { return false }
            let url: URL? = if string.hasPrefix("/") { URL(fileURLWithPath: string) } else { URL(string: string) }
            guard let url else { return false }
            // Later, not inside libghostty's callback: the first artifact
            // link asks where to open it, and that waits for an answer.
            Task { @MainActor in ArtifactLinks.open(url) }

        case GHOSTTY_ACTION_NEW_TAB:
            guard let view else { return false }
            view.delegate?.terminalRequestedNewTab(view)

        case GHOSTTY_ACTION_GOTO_TAB:
            guard let view else { return false }
            return view.delegate?.terminal(view, requestedGoToTab: action.action.goto_tab) ?? false

        case GHOSTTY_ACTION_GOTO_SPLIT:
            // With two panes, every direction goes to the other one.
            guard let view else { return false }
            return view.delegate?.terminalRequestedOtherPane(view) ?? false

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Returning false lets libghostty show its own "process exited" text.
            guard let view else { return false }
            return view.delegate?.terminalChildExited(view) ?? false

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Sent with the config actually in use, including after a
            // light/dark theme switch.
            if let changed = action.action.config_change.config {
                TerminalTheme.shared.update(from: changed)
            }
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_KEY_SEQUENCE,
             GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_SECURE_INPUT, GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT:
            // Accepted but nothing to do in Bench.
            return true

        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)

        default:
            // New Ghostty splits, windows, fullscreen, inspector, etc. Bench's
            // own splits are tabs, so Ghostty's don't apply.
            return false
        }
        return true
    }

    // MARK: Clipboard

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: .general
        default: nil
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, let pasteboard = pasteboard(location) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        guard let view = TerminalSurfaceView.view(forUserdata: userdata), let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        // Bench only serves plain text. That covers normal pastes.
        var wantsText = false
        if let mimes {
            for i in 0..<mimesLen {
                if let ptr = mimes[i], String(cString: ptr).hasPrefix("text/plain") { wantsText = true }
            }
        }
        let text = wantsText ? pasteboard.string(forType: .string) : nil
        let available = pasteboard.string(forType: .string) != nil ? ["text/plain"] : []
        if text == nil && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        complete(surface, text: text, available: list ? available : [], state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata else { return }
        guard let view = TerminalSurfaceView.view(forUserdata: userdata), let surface = view.surface else { return }

        // Only user pastes get through. Programs reading the clipboard
        // (OSC 52 and friends) are denied.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let confirm else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        let c = confirm.pointee
        var text: String?
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let item = contents[i]
                guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else { continue }
                text = String(data: Data(bytes: data, count: item.len), encoding: .utf8)
            }
        }
        complete(surface, text: text, available: [], state: state, confirmed: true)
    }

    private static func complete(
        _ surface: ghostty_surface_t,
        text: String?,
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        let mime = strdup("text/plain")
        let bytes = text.map { Array($0.utf8) } ?? []
        let availablePtrs = available.map { UnsafePointer(strdup($0)) }
        defer {
            free(mime)
            availablePtrs.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        }

        bytes.withUnsafeBufferPointer { buf in
            let raw = UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: CChar.self)
            let contents: [ghostty_clipboard_content_s] = text == nil
                ? []
                : [ghostty_clipboard_content_s(mime: mime, data: raw, len: bytes.count)]
            contents.withUnsafeBufferPointer { contentsBuf in
                availablePtrs.withUnsafeBufferPointer { availBuf in
                    var payload = ghostty_clipboard_complete_s(
                        contents: contentsBuf.baseAddress,
                        contents_len: contentsBuf.count,
                        available: availBuf.baseAddress,
                        available_len: availBuf.count,
                        confirmed: confirmed,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &payload, state)
                }
            }
        }
    }

    private static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        guard let pasteboard = pasteboard(location), let content, len > 0 else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else { continue }
            guard let string = String(data: Data(bytes: data, count: item.len), encoding: .utf8) else { continue }
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(string, forType: .string)
            return
        }
    }
}

/// Carries C pointers across an isolation boundary we've checked by hand.
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
