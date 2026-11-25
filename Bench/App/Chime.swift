import AppKit

/// Workbench's two sounds: one for Claude finishing and one for Claude
/// needing you. Each can be one of Workbench's own tones (made here from a
/// few sine notes, so there are no sound files to ship), one of the Mac's
/// alert sounds, or nothing. They play only while Workbench is in front.
/// When it isn't, the notification makes the sound.
@MainActor
enum Chime {
    /// Settings › Appearance › Sounds. Off until turned on.
    static let enabledKey = "playsSounds"
    /// Set once Workbench has asked whether to keep the sound it just
    /// played, so it only asks the first time.
    static let askedKey = "askedAboutSound"

    enum Kind: CaseIterable {
        /// Claude finished a turn.
        case finished
        /// Claude is waiting on you.
        case needsYou

        /// Where the choice is saved.
        var key: String {
            switch self {
            case .finished: "sound.finished"
            case .needsYou: "sound.needsYou"
            }
        }

        /// The sounds Workbench always had, so nothing changes until you
        /// pick something else.
        var defaultSound: ChimeSound {
            switch self {
            case .finished: .tones(.chime)
            case .needsYou: .tones(.knock)
            }
        }

        /// What the sound means, for the picker's label and the first-time
        /// question.
        var title: String {
            switch self {
            case .finished: "When an agent finishes"
            case .needsYou: "When an agent needs you"
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    static func sound(for kind: Kind) -> ChimeSound {
        UserDefaults.standard.string(forKey: kind.key).flatMap(ChimeSound.init(id:)) ?? kind.defaultSound
    }

    static func setSound(_ sound: ChimeSound, for kind: Kind) {
        UserDefaults.standard.set(sound.id, forKey: kind.key)
    }

    /// Plays the sound, unless sounds are off, Workbench isn't in front, or
    /// the same one played a moment ago (several agents finishing together
    /// make one sound, not a chord). The first time, it then asks whether
    /// to keep it.
    static func play(_ kind: Kind) {
        guard isEnabled, NSApp.isActive else { return }
        let choice = sound(for: kind)
        guard choice != .none else { return }
        let now = Date()
        if let last = lastPlayed[kind], now.timeIntervalSince(last) < 2 { return }
        lastPlayed[kind] = now
        preview(choice)
        if !UserDefaults.standard.bool(forKey: askedKey) {
            // Let the sound finish first, so it's clear what the question
            // is about.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { askToKeep(kind) }
        }
    }

    /// Plays a sound right away, for the pickers.
    static func preview(_ choice: ChimeSound) {
        guard let sound = nsSound(for: choice) else { return }
        sound.stop()
        sound.play()
    }

    private static var sounds: [ChimeSound: NSSound] = [:]
    private static var lastPlayed: [Kind: Date] = [:]

    private static func nsSound(for choice: ChimeSound) -> NSSound? {
        if let cached = sounds[choice] { return cached }
        let sound: NSSound?
        switch choice {
        case .tones(let tones):
            sound = NSSound(data: wave(notes: tones.notes))
            sound?.volume = 0.3
        case .system(let name):
            // A copy, so setting its volume leaves the shared one alone.
            sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound
            sound?.volume = 0.4
        case .none:
            sound = nil
        }
        sounds[choice] = sound
        return sound
    }

    // MARK: - The first time

    /// Asks, once, whether to keep the sound that just played, with a menu
    /// to pick another. Only when there's a window to ask in.
    private static func askToKeep(_ kind: Kind) {
        guard !UserDefaults.standard.bool(forKey: askedKey), isEnabled, NSApp.isActive,
              let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return }
        UserDefaults.standard.set(true, forKey: askedKey)

        let alert = NSAlert()
        switch kind {
        case .finished:
            alert.messageText = "That sound means an agent finished"
            alert.informativeText = "Workbench plays it when an agent finishes a turn that took a while or that you weren't watching. Pick another below if you like, or change it any time in Settings › Appearance."
        case .needsYou:
            alert.messageText = "That sound means an agent needs you"
            alert.informativeText = "Workbench plays it when an agent asks you something in a tab you aren't looking at. Pick another below if you like, or change it any time in Settings › Appearance."
        }
        let picker = SoundPopUp(selection: sound(for: kind))
        alert.accessoryView = picker.button
        alert.addButton(withTitle: "Use This Sound")
        alert.addButton(withTitle: "Turn Off Sounds")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                setSound(picker.selection, for: kind)
            } else {
                UserDefaults.standard.set(false, forKey: enabledKey)
            }
        }
    }

    // MARK: - Making the tones

    /// The notes as a WAV file in memory: 16-bit mono.
    static func wave(notes: [ChimeSound.Note]) -> Data {
        let rate = 44_100.0
        let noteLength = 0.42
        let length = (notes.map(\.start).max() ?? 0) + noteLength
        var samples = [Double](repeating: 0, count: Int(length * rate))
        for note in notes {
            let first = Int(note.start * rate)
            for offset in 0..<Int(noteLength * rate) where first + offset < samples.count {
                let time = Double(offset) / rate
                // A few milliseconds in, so it doesn't click, then a quick
                // fade like a struck bar.
                let envelope = min(1, time / 0.006) * exp(-time * 11)
                let phase = 2 * Double.pi * note.frequency * time
                samples[first + offset] += envelope * (sin(phase) + 0.18 * sin(2 * phase))
            }
        }
        let peak = max(samples.map(abs).max() ?? 1, 0.001)
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16((sample / peak * 0.8 * Double(Int16.max)).rounded())
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }

        var file = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) }
        }
        file.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))              // The format block's size.
        append(UInt16(1))               // PCM.
        append(UInt16(1))               // Mono.
        append(UInt32(rate))
        append(UInt32(rate) * 2)        // Bytes a second.
        append(UInt16(2))               // Bytes a sample.
        append(UInt16(16))              // Bits a sample.
        file.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        file.append(pcm)
        return file
    }
}

/// One choice in the sound pickers.
enum ChimeSound: Hashable, Identifiable {
    /// One of Workbench's own tones.
    case tones(Tones)
    /// One of the Mac's alert sounds, by name.
    case system(String)
    /// No sound.
    case none

    typealias Note = (frequency: Double, start: Double)

    enum Tones: String, CaseIterable {
        case chime, knock, bell, rise, fall, low

        var title: String { rawValue.capitalized }

        /// Each note's pitch and when it starts, in seconds.
        var notes: [Note] {
            switch self {
            case .chime: [(783.99, 0), (1174.66, 0.11)]                     // G5, then D6
            case .knock: [(880, 0), (880, 0.17)]                            // A5, twice
            case .bell: [(1318.51, 0)]                                      // E6
            case .rise: [(1046.5, 0), (1318.51, 0.09), (1567.98, 0.18)]     // C6, E6, G6
            case .fall: [(1174.66, 0), (783.99, 0.11)]                      // D6, then G5
            case .low: [(523.25, 0), (783.99, 0.12)]                        // C5, then G5
            }
        }
    }

    /// The Mac's alert sounds that are there on this Mac.
    static let systemNames: [String] = [
        "Glass", "Ping", "Pop", "Tink", "Purr", "Hero", "Submarine",
        "Bottle", "Blow", "Frog", "Funk", "Morse", "Sosumi", "Basso",
    ].filter { NSSound(named: NSSound.Name($0)) != nil }

    static var workbench: [ChimeSound] { Tones.allCases.map { .tones($0) } }
    static var mac: [ChimeSound] { systemNames.map { .system($0) } }

    var id: String {
        switch self {
        case .tones(let tones): "tones.\(tones.rawValue)"
        case .system(let name): "system.\(name)"
        case .none: "none"
        }
    }

    init?(id: String) {
        if id == "none" {
            self = .none
        } else if id.hasPrefix("tones."), let tones = Tones(rawValue: String(id.dropFirst(6))) {
            self = .tones(tones)
        } else if id.hasPrefix("system."), id.count > 7 {
            self = .system(String(id.dropFirst(7)))
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .tones(let tones): tones.title
        case .system(let name): name
        case .none: "None"
        }
    }
}

/// The menu of sounds in the first-time question. Choosing one plays it.
@MainActor
private final class SoundPopUp: NSObject {
    let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
    private(set) var selection: ChimeSound

    init(selection: ChimeSound) {
        self.selection = selection
        super.init()
        let menu = NSMenu()
        func add(_ sounds: [ChimeSound], header: String) {
            menu.addItem(.sectionHeader(title: header))
            for sound in sounds {
                let item = NSMenuItem(title: sound.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = sound.id
                menu.addItem(item)
            }
        }
        button.menu = menu
        add(ChimeSound.workbench, header: "Workbench")
        add(ChimeSound.mac, header: "Mac")
        if let item = menu.items.first(where: { $0.representedObject as? String == selection.id }) {
            button.select(item)
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let sound = ChimeSound(id: id) else { return }
        selection = sound
        Chime.preview(sound)
    }
}
