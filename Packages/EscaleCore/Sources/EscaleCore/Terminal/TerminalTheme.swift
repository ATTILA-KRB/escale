import Foundation

/// Couleur sRGB 8 bits d'un thème de terminal.
public struct TerminalRGB: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) { self.red = red; self.green = green; self.blue = blue }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xff), UInt8((hex >> 8) & 0xff), UInt8(hex & 0xff))
    }

    public var description: String { String(format: "#%02x%02x%02x", red, green, blue) }

    /// Luminance relative (WCAG), 0…1.
    public var luminance: Double {
        func lin(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// Rapport de contraste WCAG entre deux couleurs (1…21).
    public func contrast(with other: TerminalRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Thème de terminal : les 16 couleurs ANSI, plus le texte, le fond, le curseur et la sélection.
/// Les couleurs 16…255 (cube et gris) sont recalculées par le moteur à partir de ces 16 couleurs.
///
/// Le thème « Système » laisse `foreground`/`background`/`cursor`/`selection` à `nil` : le moteur garde alors les
/// couleurs dynamiques de macOS (texte et fond qui suivent l'apparence claire ou sombre), comme avant les thèmes.
public struct TerminalTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// 16 couleurs : 0–7 normales, 8–15 vives.
    public let ansi: [TerminalRGB]
    public let foreground: TerminalRGB?
    public let background: TerminalRGB?
    public let cursor: TerminalRGB?
    public let selectionBackground: TerminalRGB?
    public let selectionForeground: TerminalRGB?

    public init(id: String, name: String, ansi: [UInt32], foreground: UInt32?, background: UInt32?,
                cursor: UInt32?, selectionBackground: UInt32?, selectionForeground: UInt32?) {
        precondition(ansi.count == 16, "un thème porte exactement 16 couleurs ANSI")
        self.id = id; self.name = name
        self.ansi = ansi.map(TerminalRGB.init(hex:))
        self.foreground = foreground.map(TerminalRGB.init(hex:))
        self.background = background.map(TerminalRGB.init(hex:))
        self.cursor = cursor.map(TerminalRGB.init(hex:))
        self.selectionBackground = selectionBackground.map(TerminalRGB.init(hex:))
        self.selectionForeground = selectionForeground.map(TerminalRGB.init(hex:))
    }

    /// Vrai si le thème impose ses propres couleurs de texte et de fond.
    public var hasFixedColors: Bool { foreground != nil && background != nil }

    // MARK: Préréglages

    /// Défauts du moteur (palette « Terminal.app » de SwiftTerm, texte et fond du système).
    public static let system = TerminalTheme(
        id: "system", name: "Système",
        ansi: [0x000000, 0xc23621, 0x25bc24, 0xadad27, 0x492ee1, 0xd338d3, 0x33bbc8, 0xcbcccd,
               0x818383, 0xfc391f, 0x31e722, 0xeaec23, 0x5833ff, 0xf935f8, 0x14f0f0, 0xe9ebeb],
        foreground: nil, background: nil, cursor: nil, selectionBackground: nil, selectionForeground: nil)

    /// Fond noir et palette xterm : l'aspect classique des clients SSH Windows (MobaXterm, PuTTY).
    public static let classic = TerminalTheme(
        id: "classic", name: "Classique (fond noir)",
        ansi: [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x1e66ff, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
               0x7f7f7f, 0xff3b3b, 0x3bff3b, 0xffff3b, 0x6b8cff, 0xff3bff, 0x3bffff, 0xffffff],
        foreground: 0xececec, background: 0x000000, cursor: 0xb4b4c0,
        selectionBackground: 0x3a4a6a, selectionForeground: 0xffffff)

    public static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized sombre",
        ansi: [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
               0x586e75, 0xcb4b16, 0x859900, 0xb58900, 0x268bd2, 0x6c71c4, 0x2aa198, 0xfdf6e3],
        foreground: 0x93a1a1, background: 0x002b36, cursor: 0x93a1a1,
        selectionBackground: 0x0f4b5c, selectionForeground: 0xfdf6e3)

    public static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized clair",
        ansi: [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
               0x586e75, 0xcb4b16, 0x859900, 0xb58900, 0x268bd2, 0x6c71c4, 0x2aa198, 0xfdf6e3],
        foreground: 0x586e75, background: 0xfdf6e3, cursor: 0x586e75,
        selectionBackground: 0xd8d2bf, selectionForeground: 0x073642)

    public static let tango = TerminalTheme(
        id: "tango", name: "Tango sombre",
        ansi: [0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x8e6a94, 0x06989a, 0xd3d7cf,
               0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec],
        foreground: 0xd3d7cf, background: 0x1e2122, cursor: 0xd3d7cf,
        selectionBackground: 0x3f4a54, selectionForeground: 0xeeeeec)

    public static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        ansi: [0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
               0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff],
        foreground: 0xf8f8f2, background: 0x282a36, cursor: 0xf8f8f2,
        selectionBackground: 0x44475a, selectionForeground: 0xf8f8f2)

    /// Fond blanc, palette assombrie pour rester lisible sur clair.
    public static let paper = TerminalTheme(
        id: "paper", name: "Papier (clair)",
        ansi: [0x000000, 0xb20000, 0x00800b, 0x8a6d00, 0x0033b3, 0x9b009b, 0x00737a, 0x9a9a9a,
               0x5e5e5e, 0xd70000, 0x00a10f, 0xa88400, 0x2e5cff, 0xc000c0, 0x008f99, 0x6e6e6e],
        foreground: 0x1e1e1e, background: 0xffffff, cursor: 0x3a3a3a,
        selectionBackground: 0xb4d5fe, selectionForeground: 0x000000)

    /// Ordre d'affichage dans les menus.
    public static let all: [TerminalTheme] = [system, classic, solarizedDark, solarizedLight, tango, dracula, paper]

    /// Thème d'identifiant donné ; identifiant inconnu (préférence d'une version future) : `nil`.
    public static func named(_ id: String) -> TerminalTheme? { all.first { $0.id == id } }
}
