import AppKit
import AVFoundation
import Foundation
import Observation

/// Dictation in a chat's message box: hold a key (or click the microphone)
/// and talk, and what you said is typed where the cursor is. Off unless
/// it's turned on in Settings, since many people already run a dictation
/// app. Everything happens on this Mac.
///
/// The speech engine, the release tail, and the cleanup come from Dict.
/// What's different here: it only listens while Workbench is in front and
/// a message box has the cursor, so it needs no Accessibility or Input
/// Monitoring permission, only the microphone.
@Observable
final class Dictation {
    static let shared = Dictation()

    static let enabledKey = "dictation.enabled"
    static let keyKey = "dictation.key"
    static let fixesTermsKey = "dictation.fixesTerms"

    /// Where a recording is in its life.
    enum Phase: Equatable {
        case idle
        /// The key is down and the microphone (or the model) is on its way.
        case starting
        case listening
        /// Finishing the last words, transcribing, and cleaning up.
        case finishing
    }

    /// The speech model's files and whether they're loaded.
    enum ModelState: Equatable {
        /// Not on this Mac yet.
        case missing
        case downloading(Double)
        /// On disk, being loaded.
        case loading
        case ready
        /// On disk, not loaded: dictation is off.
        case unloaded
        case failed(String)
    }

    /// The message box a dictation goes into.
    struct Target {
        let id: UUID
        let insert: (String) -> Void
    }

    // MARK: Settings

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            enabledChanged()
            if isEnabled { Analytics.capture(.dictationEnabled) }
        }
    }

    var key: DictationKey {
        didSet {
            guard key != oldValue else { return }
            defaults.set(key.rawValue, forKey: Self.keyKey)
            cancel()
        }
    }

    /// Whether Apple's language model fixes technical terms.
    var fixesTerms: Bool {
        didSet {
            guard fixesTerms != oldValue else { return }
            defaults.set(fixesTerms, forKey: Self.fixesTermsKey)
        }
    }

    // MARK: State

    private(set) var phase: Phase = .idle
    /// True once Space (or the microphone button) set the recording going
    /// without the key held.
    private(set) var isHandsFree = false
    private(set) var modelState: ModelState
    fileprivate(set) var microphone: AVAuthorizationStatus
    /// The message box being dictated into, or that a note is about.
    private(set) var activeTarget: UUID?
    /// A short note for that box when a dictation produced nothing.
    private(set) var note: String?

    /// How loud the microphone is, 0...1.
    var level: Float { stagedLevel ?? engine.level }
    /// A level set by hand, for the preview pictures.
    private var stagedLevel: Float?
    var isBusy: Bool { phase != .idle }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine = ParakeetEngine()
    @ObservationIgnored private var logic = DictationKeyLogic()
    @ObservationIgnored private var focused: Target?
    @ObservationIgnored private var recordingInto: Target?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        key = defaults.string(forKey: Self.keyKey).flatMap(DictationKey.init(rawValue:)) ?? .rightOption
        fixesTerms = defaults.object(forKey: Self.fixesTermsKey) as? Bool ?? true
        modelState = ParakeetEngine.isModelDownloaded ? .unloaded : .missing
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Turning on and off

    /// Called once at launch. Does nothing while dictation is off.
    func start() {
        guard !started else { return }
        started = true
        if isEnabled { enabledChanged() }
    }

    private func enabledChanged() {
        guard started else { return }
        if isEnabled {
            watchKey()
            requestMicrophone()
            prepareModel()
        } else {
            cancel()
            unwatchKey()
            engine.unload()
            modelState = ParakeetEngine.isModelDownloaded ? .unloaded : .missing
        }
    }

    /// Downloads the model if it's missing (about 500 MB, once) and loads
    /// it, so the first press of the key is ready to go.
    func prepareModel() {
        switch modelState {
        case .downloading, .loading, .ready: return
        case .missing, .unloaded, .failed: break
        }
        guard isEnabled else { return }
        modelState = ParakeetEngine.isModelDownloaded ? .loading : .downloading(0)
        engine.onProgress = { [weak self] fraction in
            guard let self, case .downloading = self.modelState else { return }
            self.modelState = .downloading(fraction)
        }
        Task {
            do {
                try await engine.prepare()
                // Turned off while it was loading.
                guard isEnabled else { engine.unload(); return }
                modelState = .ready
            } catch {
                DictationLog.pipeline.error("Model failed to load: \(String(describing: error), privacy: .public)")
                guard isEnabled else { return }
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    /// Asks for the microphone the first time. Later calls just refresh
    /// what's known, in case it was changed in System Settings.
    func requestMicrophone() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        guard microphone == .notDetermined else { return }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    // MARK: - The message box

    /// A message box got the cursor: the key now dictates into it.
    func focus(_ target: Target) {
        focused = target
    }

    func blur(_ id: UUID) {
        if focused?.id == id { focused = nil }
    }

    /// The microphone button: starts a hands-free dictation, or finishes
    /// the one that's going.
    func toggle(_ target: Target) {
        switch phase {
        case .idle:
            focused = target
            guard begin(handsFree: true) else { return }
            logic.beganHandsFree()
        case .starting, .listening:
            logic.reset()
            finish()
        case .finishing:
            break
        }
    }

    // MARK: - Keys

    private func watchKey() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsChanged(event)
            return event
        }
        // A key held while switching apps never reports its release here.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isBusy, !self.isHandsFree, self.phase != .finishing else { return }
                self.cancel()
            }
        }
    }

    private func unwatchKey() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == key.keyCode else { return }
        if logic.isKeyHeld {
            perform(logic.keyUp())
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        // Only the key by itself: with another modifier down it's part of
        // a shortcut.
        guard modifiers == key.flag else { return }
        // Starting needs a message box with the cursor. Finishing a
        // hands-free recording doesn't.
        guard logic.isRecording || focused != nil else { return }
        perform(logic.keyDown())
    }

    /// A key pressed in a message box. Returns true when dictation used
    /// it and it shouldn't be typed.
    func keyDown(_ event: NSEvent) -> Bool {
        guard isEnabled, isBusy else { return false }
        switch event.keyCode {
        case 53:
            // Escape throws away a recording, or one being written out.
            cancel()
            return true
        case 49 where logic.swallowsSpace:
            perform(logic.spaceDown())
            return true
        default:
            perform(logic.otherKeyDown())
            return false
        }
    }

    private func perform(_ action: DictationKeyLogic.Action?) {
        switch action {
        case .start:
            if !begin(handsFree: false) { logic.reset() }
        case .stop: finish()
        case .cancel: cancel()
        case .enterHandsFree: isHandsFree = true
        case nil: break
        }
    }

    // MARK: - Recording

    /// Starts listening for the message box with the cursor. False when it
    /// couldn't: nothing to dictate into, no microphone, or already busy.
    @discardableResult
    private func begin(handsFree: Bool) -> Bool {
        guard isEnabled, phase == .idle, let target = focused else { return false }
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphone {
        case .authorized: break
        case .notDetermined:
            requestMicrophone()
            return false
        default:
            show("Workbench needs the microphone. Allow it in System Settings, under Privacy & Security.", for: target.id, seconds: 6)
            return false
        }
        // The model has to be loaded first. Say so rather than record
        // into nothing, and get it going if it isn't already.
        guard engine.isReady else {
            switch modelState {
            case .downloading: show("The speech model is still downloading. Settings shows how far along it is.", for: target.id, seconds: 4)
            case .loading: show("The speech model is still loading. Try again in a moment.", for: target.id)
            case .missing, .unloaded, .failed, .ready:
                prepareModel()
                show("Getting the speech model ready. Try again in a moment.", for: target.id)
            }
            return false
        }
        clearNote()
        recordingInto = target
        activeTarget = target.id
        isHandsFree = handsFree
        phase = .starting
        let device = AudioInputDevices.automatic()
        work = Task {
            do {
                try await engine.start(deviceID: device?.id)
                if phase == .starting, engine.isRecording { phase = .listening }
            } catch {
                DictationLog.pipeline.error("Couldn't start: \(String(describing: error), privacy: .public)")
                guard phase == .starting || phase == .listening else { return }
                logic.reset()
                engine.cancel()
                end()
                show("Couldn't start the microphone.", for: target.id)
            }
        }
        return true
    }

    /// Stops listening, then transcribes, cleans up, and types the result.
    private func finish() {
        guard phase == .starting || phase == .listening, let target = recordingInto else { return }
        phase = .finishing
        let handsFree = isHandsFree
        let fixesTerms = fixesTerms
        work = Task {
            let raw: String
            do {
                raw = try await engine.stop(waitsForQuiet: true)
            } catch {
                DictationLog.pipeline.error("Transcription failed: \(String(describing: error), privacy: .public)")
                guard !Task.isCancelled else { return }
                end()
                show("Couldn't transcribe that. Try again.", for: target.id)
                return
            }
            guard !Task.isCancelled else { return }
            guard !raw.isEmpty else {
                end()
                show("Didn't catch anything.", for: target.id)
                return
            }
            let text = await DictationCleanup.clean(raw, fixingTerms: fixesTerms)
            // Escape while it was being written out.
            guard !Task.isCancelled else { return }
            DictationLog.pipeline.notice("Dictation: \(Self.wordCount(raw), privacy: .public) words heard, \(Self.wordCount(text), privacy: .public) typed")
            end()
            target.insert(text)
            Analytics.capture(.dictationUsed, ["hands_free": handsFree, "fixes_terms": fixesTerms])
        }
    }

    /// Throws away the recording, or the transcription in flight.
    func cancel() {
        guard isBusy else { return }
        work?.cancel()
        work = nil
        engine.cancel()
        logic.reset()
        end()
    }

    private func end() {
        phase = .idle
        isHandsFree = false
        recordingInto = nil
        if note == nil { activeTarget = nil }
    }

    // MARK: - Notes

    private func show(_ text: String, for id: UUID, seconds: Double = 2.5) {
        noteTask?.cancel()
        note = text
        activeTarget = id
        noteTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            note = nil
            if !isBusy { activeTarget = nil }
        }
    }

    private func clearNote() {
        noteTask?.cancel()
        noteTask = nil
        note = nil
    }

    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

extension Dictation {
    /// Settings is showing: pick up a change made in System Settings.
    func requestMicrophoneIfEnabled() {
        if isEnabled { requestMicrophone() } else { microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
    }
}

#if DEBUG
extension Dictation {
    /// Puts dictation in a state by hand, for DictationPreview's pictures.
    /// Nothing is recorded and nothing is saved.
    func stage(phase: Phase, handsFree: Bool, level: Float, note: String?, target: UUID) {
        self.phase = phase
        isHandsFree = handsFree
        stagedLevel = level
        self.note = note
        activeTarget = phase != .idle || note != nil ? target : nil
    }

    func stage(enabled: Bool, model: ModelState) {
        started = false
        // The switch saves itself, and a Debug build shares the real
        // app's settings: put back whatever was saved.
        let saved = defaults.object(forKey: Self.enabledKey)
        isEnabled = enabled
        if let saved { defaults.set(saved, forKey: Self.enabledKey) } else { defaults.removeObject(forKey: Self.enabledKey) }
        modelState = model
    }
}
#endif
