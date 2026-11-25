import Foundation

/// A color theme that ships with Workbench, for people who don't want the
/// app to follow their Ghostty theme. The Mac uses it for the terminal tabs
/// and the window around them; the phone builds its colors from it.
public struct BuiltInTheme: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let background: TerminalColors.RGB
    public let foreground: TerminalColors.RGB
    public let cursor: TerminalColors.RGB
    public let selection: TerminalColors.RGB
    /// The 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan,
    /// white, then their bright versions.
    public let palette: [TerminalColors.RGB]

    public var isDark: Bool { background.luminance < 0.5 }

    /// Written as "bg fg cursor selection", then the eight normal colors,
    /// then the eight bright ones, so the list below stays easy to scan.
    init(_ id: String, _ name: String, _ base: String, _ normal: String, _ bright: String) {
        func colors(_ text: String) -> [TerminalColors.RGB] {
            text.split(separator: " ").map { TerminalColors.RGB(hex: String($0)) }
        }
        let main = colors(base)
        self.id = id
        self.name = name
        background = main[0]
        foreground = main[1]
        cursor = main[2]
        selection = main[3]
        palette = colors(normal) + colors(bright)
    }

    /// The theme as a Ghostty theme file.
    public var ghosttyConfig: String {
        var lines = [
            "background = \(background.hex)",
            "foreground = \(foreground.hex)",
            "cursor-color = \(cursor.hex)",
            "cursor-text = \(background.hex)",
            "selection-background = \(selection.hex)",
            "selection-foreground = \(foreground.hex)",
        ]
        for (index, color) in palette.enumerated() {
            lines.append("palette = \(index)=\(color.hex)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The colors the phone and the chat are built from.
    public var terminalColors: TerminalColors {
        // Inline code takes the theme's blue, the way Claude Code colors it
        // in the terminal: the bright one on dark themes, the normal one on
        // light themes.
        let accent = TerminalColors.accent(fromCursor: cursor)
        let status = TerminalColors.statusColors(palette: palette, background: background, foreground: foreground,
                                                 accent: accent)
        return TerminalColors(background: background, foreground: foreground, code: palette[isDark ? 12 : 4],
                              accent: accent, done: status.done, working: status.working)
    }

    public static func named(_ id: String?) -> BuiltInTheme? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    public static var light: [BuiltInTheme] { all.filter { !$0.isDark } }
    public static var dark: [BuiltInTheme] { all.filter(\.isDark) }

    /// What a new install starts with when there's no Ghostty theme to
    /// follow.
    public static let defaultLightID = "clean-slate"
    public static let defaultDarkID = "northern-lights"
    public static var defaultLight: BuiltInTheme { named(defaultLightID)! }
    public static var defaultDark: BuiltInTheme { named(defaultDarkID)! }

    public static let all: [BuiltInTheme] = [
        // Light
        .init("clean-slate", "Clean Slate", "FFFFFF 202227 2563EB DBE6FB",
              "202227 D12F3A 21803F 9C6B05 2563EB 8247D9 15808A D4D8DE",
              "6B7280 E44C55 2F9A52 B98510 3B82F6 9A62EE 1F99A4 FFFFFF"),
        .init("oat-milk", "Oat Milk", "F5F1E8 3B362E C0572F E4DCCB",
              "3B362E B4442F 5B7F2E A0741A 3B6EA8 8D4F94 2E7F7A D9D1C1",
              "8A8273 D0573E 6E9638 BC8A24 4F86C2 A665AD 3B9690 F5F1E8"),
        .init("rice-paper", "Rice Paper", "FAFAF8 2A2A28 2A2A28 E3E3DF",
              "2A2A28 B8352E 3E7D32 98700F 2F5FB3 8A3F9E 26787F DCDCD7",
              "85857F CF4A42 4F9640 B3861A 4677CC A355B5 32919A FAFAF8"),
        .init("sea-glass", "Sea Glass", "EEF6F2 24403A 1F8A78 CFE6DD",
              "24403A C2463F 2F8A4E A87B12 2D6FB0 8650A6 1B8A86 D3E4DC",
              "738D85 D95A51 3EA35F C2911D 4387C9 9F68BF 22A39E EEF6F2"),
        .init("harbor-morning", "Harbor Morning", "F2F5FA 1F2B3D 2E6BD6 D6E1F2",
              "1F2B3D C23B3B 2F7F4A 9A6F0F 2E64C7 8146B3 1C7C94 D5DCE7",
              "75839A D85050 3C985A B78417 4A7EE0 9A5ECB 2694AE F2F5FA"),
        .init("linen-sky", "Linen Sky", "F4F1EC 2C3440 3C78C6 DCE3EE",
              "2C3440 B9473E 4E7E3A 9D7419 3A6AB4 8851A0 2A7D8C DCD7CE",
              "7C8492 D05C52 5F9647 B98922 5282CB A067B8 3595A6 F4F1EC"),
        .init("lilac-letter", "Lilac Letter", "F5F2FA 352F45 7A55C7 E2DAF2",
              "352F45 BC3F5B 3F8253 9C7417 4D63C2 8A4FC0 2E7E95 DCD5E8",
              "857D99 D4566F 50995F B88A20 6479D6 A066D6 3D97AE F5F2FA"),
        .init("sakura-note", "Sakura Note", "FBF1F3 45303A D0567A F1D6DE",
              "45303A C23B5A 4D7F45 A27419 4A65B5 A04A92 2F7E8A E9D6DC",
              "977D88 D9516F 5F9757 BE8A22 6079CC B862A8 3D96A2 FBF1F3"),
        .init("apricot-porch", "Apricot Porch", "FBF0E6 45332A D06A3A F0D9C6",
              "45332A BF4A33 5E7F2F A9761B 3F6A9E 9A4F7A 3B8075 E9D9CA",
              "958072 D65F45 72963B C48C25 5682B6 B26490 4A988C FBF0E6"),
        .init("clay-studio", "Clay Studio", "F8EEE7 3F2A22 B4532A EDD5C7",
              "3F2A22 B23A26 5C7A2C A16E1C 3D639B 94506E 33796F E5D3C7",
              "917568 CC4F38 6F9236 BC8526 5379B3 AC6686 409186 F8EEE7"),
        .init("honeycomb", "Honeycomb", "FAF4DD 3D3520 B5841A EEE2B8",
              "3D3520 B8442C 5E7D22 9A6E0A 3D63A0 8E4C86 2E7B70 E6DCBC",
              "8C8160 D0583F 70952B B58410 5379B8 A6619E 3B9285 FAF4DD"),
        .init("fern-garden", "Fern Garden", "F2F5EA 2F3A26 4F8A2E DDE5CC",
              "2F3A26 B5482F 4C7F25 997317 3D68A3 8B5291 2F7F6F DAE0CC",
              "7E8A70 CE5D42 5E9830 B5891F 547FBC A3699F 3C9785 F2F5EA"),
        .init("saltmarsh", "Saltmarsh", "EFF1EC 2E3530 527A6A D7DDD3",
              "2E3530 AC4A3E 547A3F 937222 49688F 7D5B88 3E7A76 D6DBD2",
              "7D877F C35F52 66924D AE8829 5E80A8 9670A0 4B928D EFF1EC"),
        .init("graphite-sketch", "Graphite Sketch", "F4F4F4 1E1E1E 1E1E1E DADADA",
              "1E1E1E 4A4A4A 5E5E5E 6E6E6E 3A3A3A 545454 666666 D0D0D0",
              "888888 333333 4A4A4A 5A5A5A 262626 3F3F3F 525252 F4F4F4"),

        // Dark
        .init("northern-lights", "Northern Lights", "111522 D8E0F0 7CF0C0 283050",
              "1C2234 F07890 7CE0A8 E8D47C 7CA4F0 B48CF0 70D4E8 B8C0D8",
              "5D6783 FF90A6 98F0BE F4E098 98BAFF C8A6FF 8CE4F4 F0F4FC"),
        .init("deep-harbor", "Deep Harbor", "0F1A24 C8D6E0 3FD0C0 23384A",
              "1A2835 E06C6C 6CC490 E0C070 5FA8E0 B08AE0 4FC8C8 A8B8C4",
              "576C7B F08484 84D8A4 F0D088 7ABCF0 C4A0F0 6ADCDC E4EEF4"),
        .init("studio-charcoal", "Studio Charcoal", "1C1C1E DCDCDC F06A4A 3A3A3E",
              "2A2A2E E8705A A8C080 E0C080 8CA8D0 C49AC8 88C4C0 BEBEBE",
              "6B6B70 F48A74 BCD49A F0D49A A4BCE0 D6B0DA A0D8D4 F2F2F2"),
        .init("ink-noir", "Ink Noir", "0A0A0A E8E8E8 FF4430 2E2E2E",
              "1A1A1A FF4430 A8D888 F0D048 88A8F0 C898F0 80D8E0 C8C8C8",
              "636363 FF6A58 C0E8A0 FFE070 A4BCFF DAB0FF 9CE8F0 FFFFFF"),
        .init("indigo-works", "Indigo Works", "141A2E D4DAF0 8AA8FF 2A3458",
              "1E2640 E87A8A 8CCC98 E4C47C 7898F0 B08CF0 70C4E0 B4BCD8",
              "626B92 F494A2 A4DEAE F2D696 94B0FF C6A4FF 8CD8F0 EEF1FC"),
        .init("glacier-night", "Glacier Night", "121A22 D6E4EC A0D8F0 26384A",
              "1C2632 E08890 90D0B0 E0D098 88B4E0 B8A4E0 88D4E0 B4C4D0",
              "5A6D7C F0A0A8 A8E0C4 F0E0B0 A0C8F0 CCBAF0 A0E4F0 F0F8FC"),
        .init("lagoon", "Lagoon", "0E1C1E CCE2E0 5CD8C8 1E3C40",
              "18292C E8846C 88D0A0 E0C878 70B0D8 B09CD8 5CD0C8 ACC8C4",
              "537174 F49C86 A0E0B6 F0D892 8CC4E8 C6B2E8 78E0D8 EAF6F4"),
        .init("fern-hollow", "Fern Hollow", "101A14 CFE0CC 8CE07A 233A28",
              "1A261E D88A6C 8CD47A D8C870 80B0C8 B89CC8 7CCCB0 B0C4AC",
              "57705C E8A084 A4E492 E8D88A 98C4DC CCB2DA 94DCC4 ECF6EA"),
        .init("cedar-smoke", "Cedar Smoke", "1A1E1B D2DACF A8D4A0 323A34",
              "262C28 D88878 A8CC94 DCC88C 94B0C4 BCA0C4 94C8BC B4BCB2",
              "656F69 E89E8E BCDCAA ECD8A2 AAC4D8 D0B6D8 AADCD0 EEF2EC"),
        .init("driftwood", "Driftwood", "1E1C1A D8D0C4 E0A060 3A3530",
              "2A2724 D87A6A 9CB878 D8B470 8AA4C8 C094B8 84B8AC B8B0A4",
              "736D64 E8907E B0CC8C E8C688 A0B8DA D4A8CC 98CCC0 F0E8DC"),
        .init("desert-night", "Desert Night", "1C1916 E2D6C2 E8B070 3C342C",
              "2A2622 D88A6A A8B878 E0B878 8CA8C0 B898B0 90BCA8 C2B6A4",
              "74695B E8A080 BCCC90 F0CC90 A4BCD4 CCAEC4 A8D0BE F2E8D8"),
        .init("hearth", "Hearth", "1F1814 E8D8C0 E8A848 40322A",
              "2E2620 D8785C A8B470 E4B460 90A0B8 C08C9C 94B4A0 C8B8A4",
              "776757 E89070 BCC888 F0C878 A8B6CC D4A2B0 ACC8B6 F4E8D4"),
        .init("ember-ridge", "Ember Ridge", "1C1512 E6D6C8 F07838 3E2C24",
              "2C211C F0703C B4C070 F0B048 A890C8 E08A9C 9CC0A8 C8B8AA",
              "786458 FF8A54 C8D488 FFC468 BCA6DA F0A2B2 B4D4BE F4E8DC"),
        .init("bordeaux-study", "Bordeaux Study", "1F1414 E4D4CC D86450 442828",
              "2E2020 D8644E B0B878 DCB46C 9CA4C4 C090A8 9CBCAC C4B4AC",
              "7A635C E87C66 C4CC90 ECC888 B2BAD6 D4A6BC B2D0C2 F2E6E0"),
        .init("rosewood", "Rosewood", "1E1418 EAD8DE F088B0 40283A",
              "2C1E24 F0809A B4CC94 E8C48C 98A8D8 D898C8 90C8C0 CCB8C0",
              "79616D FF98B0 C8DCAA F4D6A4 B0BEE8 E8B0D8 A8DAD2 F8EAF0"),
        .init("plum-velvet", "Plum Velvet", "1C1626 E4DCF0 C4A0FF 3A2E50",
              "28203A E888A8 A8D8A0 E8D090 98A8F0 C4A0F0 90D0D8 C4BAD4",
              "71658B F8A0BC BCE8B4 F4DEA8 B0BEFF D4B6FF A8E0E8 F4F0FA"),
        .init("saffron-dusk", "Saffron Dusk", "191726 E8E2D4 F4C030 343050",
              "24213A E87C68 A8C880 F4C030 8C9CE0 C098D8 84C8C0 C8C2B8",
              "6B6583 F8947E BCD898 FFD050 A4B4F0 D4AEE8 9CD8D0 F6F2E8"),
        .init("ultraviolet", "Ultraviolet", "17121F E4DAF0 F070D8 3A2C50",
              "241C30 F06A8E 70E0A8 F0D070 8A9CFF C08AFF 70D8E8 C4B8D6",
              "706384 FF86A6 8CF0BC FFE08C A4B4FF D4A6FF 8CE8F4 F4EEFC"),
        .init("pinball", "Pinball", "120E1C EAE6F8 FF4FD8 33264A",
              "201A30 FF4F7A 4FFFA0 FFE14F 4FA8FF C060FF 4FE8FF C8C0E0",
              "6A5F85 FF7896 7CFFB8 FFEC80 7CC0FF D488FF 80F0FF FFFFFF"),
        .init("amber-glow", "Amber Glow", "1A1206 FFB548 FFC860 3D2A0C",
              "2A1E0C E8783A D8B040 FFB030 E09040 E8A050 F0C060 F0C890",
              "82602D FF8F50 F0C850 FFC448 F0A458 FFB868 FFD478 FFE0B0"),
        .init("green-phosphor", "Green Phosphor", "0B140C 7CF08C A0FFA8 1E3A22",
              "142016 C8E070 6CE07C B8F070 70D8A0 98E890 80F0B8 A8E8B0",
              "407248 D8F088 8CF89C CCFC88 8CE8B4 B0F4A8 9CF8CC D8FCDC"),
        .init("graphite-night", "Graphite Night", "161616 D8D8D8 FFFFFF 383838",
              "262626 C8C8C8 A8A8A8 E0E0E0 909090 B8B8B8 9C9C9C C0C0C0",
              "696969 E0E0E0 C4C4C4 F0F0F0 ACACAC D0D0D0 B8B8B8 FAFAFA"),
    ]
}

extension TerminalColors.RGB {
    /// From "RRGGBB".
    public init(hex: String) {
        let value = Int(hex, radix: 16) ?? 0
        self.init(r: Double((value >> 16) & 0xFF) / 255,
                  g: Double((value >> 8) & 0xFF) / 255,
                  b: Double(value & 0xFF) / 255)
    }

    /// "#rrggbb".
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}
