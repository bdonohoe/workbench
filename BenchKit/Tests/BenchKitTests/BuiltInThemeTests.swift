import Foundation
import Testing
@testable import BenchKit

struct BuiltInThemeTests {
    @Test func everyThemeIsComplete() {
        #expect(Set(BuiltInTheme.all.map(\.id)).count == BuiltInTheme.all.count)
        for theme in BuiltInTheme.all {
            #expect(theme.palette.count == 16, "\(theme.id)")
            #expect(theme.ghosttyConfig.contains("palette = 15="), "\(theme.id)")
        }
        #expect(!BuiltInTheme.defaultLight.isDark)
        #expect(BuiltInTheme.defaultDark.isDark)
    }

    @Test func textIsReadable() {
        func contrast(_ a: TerminalColors.RGB, _ b: TerminalColors.RGB) -> Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            func lum(_ c: TerminalColors.RGB) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }
            let (x, y) = (lum(a), lum(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for theme in BuiltInTheme.all {
            #expect(contrast(theme.foreground, theme.background) >= 7, "\(theme.id) text")
            // Dim text (bright black) has to stay legible.
            #expect(contrast(theme.palette[8], theme.background) >= 3, "\(theme.id) dim text")
        }
    }

    /// The checklist's green comes from each theme, read as text on its
    /// background, and stays green, or the theme leaves it to the app.
    @Test func doneColorFollowsTheTheme() {
        for theme in BuiltInTheme.all {
            guard let done = theme.terminalColors.done else { continue }
            #expect(done.contrast(on: theme.background) >= 4.5, "\(theme.id) done reads")
            #expect((60...170).contains(done.hue), "\(theme.id) done is green")
            #expect(done.chroma >= 0.1, "\(theme.id) done stays colorful")
        }
        let themed = BuiltInTheme.all.filter { $0.terminalColors.done != nil }
        #expect(themed.count >= BuiltInTheme.all.count - 4, "\(themed.count) of \(BuiltInTheme.all.count)")
        // Gray and amber themes keep the app's own.
        #expect(BuiltInTheme.named("graphite-sketch")?.terminalColors.done == nil)
        #expect(BuiltInTheme.named("amber-glow")?.terminalColors.done == nil)
    }

    /// Working takes the theme's accent unless that would look like
    /// another state, and always reads as text on the background.
    @Test func workingColorFollowsTheAccent() {
        for theme in BuiltInTheme.all {
            let colors = theme.terminalColors
            guard let working = colors.working else { continue }
            #expect(working.contrast(on: theme.background) >= 4.5, "\(theme.id) working reads")
            if let accent = colors.accent, !TerminalColors.clashingHues.contains(accent.hue) {
                #expect(abs(working.hue - accent.hue) < 12, "\(theme.id) working is its accent")
            } else if colors.accent != nil {
                #expect(working.chroma >= 0.12, "\(theme.id) working takes its orange, not a gray")
            }
            // Never green, amber or blue when it has color.
            if working.chroma >= 0.12 {
                #expect(!TerminalColors.clashingHues.contains(working.hue), "\(theme.id) working clashes")
            }
        }
        let named = { (id: String) in BuiltInTheme.named(id)!.terminalColors }
        // A pink accent shows; a blue, green or amber one falls back to
        // orange (the theme's, or the app's when it has none), never gray.
        #expect(named("sakura-note").working!.chroma >= 0.12)
        for id in ["clean-slate", "fern-hollow", "saffron-dusk"] {
            if let working = named(id).working {
                #expect(working.chroma >= 0.12, "\(id) working has color")
                #expect(!TerminalColors.clashingHues.contains(working.hue), "\(id) working is orange")
            }
        }
        // A gray cursor is no accent, and the app keeps its orange.
        #expect(named("graphite-night").working == nil)
    }

    @Test func workingColorRule() {
        let dark = TerminalColors.RGB(hex: "1A1A1A"), light = TerminalColors.RGB(hex: "EEEEEE")
        let purple = TerminalColors.RGB(hex: "C4A0FF"), blue = TerminalColors.RGB(hex: "2563EB")
        let orange = TerminalColors.RGB(hex: "D97757")
        #expect(TerminalColors.workingColor(accent: purple, orange: orange, background: dark, foreground: light) == purple)
        // A clashing accent gives way to the orange, or to the app's own
        // when the theme's orange leans amber.
        #expect(TerminalColors.workingColor(accent: blue, orange: orange, background: dark, foreground: light) == orange)
        let amberish = TerminalColors.RGB(hex: "E0A030")
        #expect(TerminalColors.workingColor(accent: blue, orange: amberish, background: dark, foreground: light) == nil)
        #expect(TerminalColors.workingColor(accent: nil, orange: orange, background: dark, foreground: light) == orange)
        #expect(TerminalColors.workingColor(accent: nil, orange: nil, background: dark, foreground: light) == nil)
    }

    @Test func readableKeepsOrDeepensAColor() {
        let white = TerminalColors.RGB(r: 1, g: 1, b: 1)
        let paleGreen = TerminalColors.RGB(hex: "7FD48F")
        let fixed = paleGreen.readable(on: white, contrast: 4.5)
        #expect(fixed.contrast(on: white) >= 4.5)
        #expect(fixed.g > fixed.r && fixed.g > fixed.b)
        let deepGreen = TerminalColors.RGB(hex: "1A7F37")
        #expect(deepGreen.readable(on: white, contrast: 4.5) == deepGreen)
        // Too few colors: nothing to take.
        let none = TerminalColors.statusColors(palette: [], background: white, foreground: .init(r: 0, g: 0, b: 0), accent: nil)
        #expect(none.done == nil && none.working == nil)
    }
}
