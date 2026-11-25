import AppKit
import Testing
@testable import Bench

/// Workbench's own sounds are made in code, so check they are sounds: a WAV
/// file the system can load, under a second long. And check the choices
/// save and read back.
@MainActor
struct ChimeTests {
    @Test(arguments: ChimeSound.Tones.allCases)
    func eachToneLoadsAndIsShort(tones: ChimeSound.Tones) throws {
        let sound = try #require(NSSound(data: Chime.wave(notes: tones.notes)))
        #expect(sound.duration > 0.3)
        #expect(sound.duration < 1)
    }

    @Test func theTonesAllDiffer() {
        let waves = Set(ChimeSound.Tones.allCases.map { Chime.wave(notes: $0.notes) })
        #expect(waves.count == ChimeSound.Tones.allCases.count)
    }

    @Test func theMacSoundsAreThere() {
        #expect(ChimeSound.systemNames.contains("Glass"))
    }

    @Test func choicesRoundTripThroughTheirIDs() {
        for sound in ChimeSound.workbench + ChimeSound.mac + [.none] {
            #expect(ChimeSound(id: sound.id) == sound)
        }
        #expect(ChimeSound(id: "tones.nope") == nil)
        #expect(ChimeSound(id: "system.") == nil)
        #expect(ChimeSound(id: "") == nil)
    }

    @Test func eachKindKeepsItsOldSoundUntilYouPickAnother() {
        let defaults = UserDefaults.standard
        let saved = Chime.Kind.allCases.map { defaults.object(forKey: $0.key) }
        defer { for (kind, value) in zip(Chime.Kind.allCases, saved) { defaults.set(value, forKey: kind.key) } }

        for kind in Chime.Kind.allCases { defaults.removeObject(forKey: kind.key) }
        #expect(Chime.sound(for: .finished) == .tones(.chime))
        #expect(Chime.sound(for: .needsYou) == .tones(.knock))

        Chime.setSound(.system("Glass"), for: .finished)
        Chime.setSound(.none, for: .needsYou)
        #expect(Chime.sound(for: .finished) == .system("Glass"))
        #expect(Chime.sound(for: .needsYou) == .none)

        defaults.set("garbage", forKey: Chime.Kind.finished.key)
        #expect(Chime.sound(for: .finished) == .tones(.chime))
    }

    @Test func soundsAreOffUntilTurnedOn() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Chime.enabledKey)
        defer { defaults.set(saved, forKey: Chime.enabledKey) }
        defaults.removeObject(forKey: Chime.enabledKey)
        #expect(!Chime.isEnabled)
        defaults.set(true, forKey: Chime.enabledKey)
        #expect(Chime.isEnabled)
    }
}
