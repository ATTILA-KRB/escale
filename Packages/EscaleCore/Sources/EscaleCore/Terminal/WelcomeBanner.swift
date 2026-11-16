import Foundation

/// Bannière d'accueil du terminal local (façon MobaXterm) : logo « ESCALE » en blocs jaunes, puis un cadre
/// d'informations (version, shell, raccourcis). Texte pur avec séquences ANSI (256 couleurs), injecté dans
/// l'écran du moteur avant la sortie du shell : rien n'est envoyé au shell, rien n'apparaît dans son historique.
/// N'affiche ni nom d'utilisateur ni nom de machine (captures publiables).
public enum WelcomeBanner {
    /// Glyphes « ANSI Shadow » (6 lignes, 8 colonnes chacun).
    static let glyphs: [Character: [String]] = [
        "E": ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"],
        "S": ["███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"],
        "C": [" ██████╗", "██╔════╝", "██║     ", "██║     ", "╚██████╗", " ╚═════╝"],
        "A": [" █████╗ ", "██╔══██╗", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
        "L": ["██╗     ", "██║     ", "██║     ", "██║     ", "███████╗", "╚══════╝"],
    ]

    /// Lignes du logo, sans couleur (largeur 48).
    public static let logo: [String] = (0..<6).map { row in "ESCALE".map { glyphs[$0]![row] }.joined() }
    public static var logoWidth: Int { logo[0].count }

    // Couleurs 24 bits (la palette 256 de SwiftTerm rend ces jaunes ternes) : dégradé jaune doré → orangé de haut en
    // bas, ombre ambre sombre, puces cyan. Couleur codée 0xRRGGBB.
    static let rowColors = [0xFFE45C, 0xFFD43B, 0xFFC52E, 0xFFB224, 0xFF9F1C, 0xFF8A14]
    static let shadow = 0xA0661A
    static let accent = 0x5FD7FF
    static let dim = 0x8A8A8A
    static let gold = 0xFFC52E

    static func fg(_ c: Int) -> String { "\u{1b}[38;2;\((c >> 16) & 0xFF);\((c >> 8) & 0xFF);\(c & 0xFF)m" }
    static let reset = "\u{1b}[0m"
    static let bold = "\u{1b}[1m"

    /// Une ligne du logo colorée : blocs pleins en jaune vif (gras), traits d'ombre en ambre.
    static func colored(_ line: String, row: Int) -> String {
        var out = "", current = -1
        for ch in line {
            let c = ch == "█" ? rowColors[row] : (ch == " " ? current : shadow)
            if c != current, ch != " " { out += (ch == "█" ? bold : reset) + fg(c); current = c }
            out.append(ch)
        }
        return out + reset
    }

    /// Bannière complète pour un écran de `columns` colonnes. Sous la largeur du logo : titre compact sur une ligne.
    /// Fins de ligne CRLF (l'écran n'est pas encore en mode « nouvelle ligne » du pty).
    public static func render(columns: Int, version: String, shell: String) -> String {
        let indent = "  "
        var lines: [String] = [""]
        if columns >= logoWidth + indent.count {
            for (i, l) in logo.enumerated() { lines.append(indent + colored(l, row: i)) }
        } else {
            lines.append(indent + bold + fg(gold) + "▌ ESCALE" + reset)
        }
        lines.append("")
        let info: [(String, String)] = [
            ("•", "\(bold)\(fg(gold))Escale \(version)\(reset) — client SSH pour macOS"),
            ("➤", "Terminal local : \(bold)\(shell)\(reset)"),
            ("➤", "Connexion rapide \(fg(gold))⇧⌘K\(reset)   Accueil \(fg(gold))⇧⌘H\(reset)"),
            ("➤", "Monitoring distant \(fg(gold))⌥⌘U\(reset)   Mode compact \(fg(gold))⇧⌘M\(reset)"),
            ("➤", "Sessions, Fichiers (SFTP), Outils et Macros dans la barre latérale"),
        ]
        let rows = info.map { (mark, text) in (mark, text, visibleWidth(text)) }
        let inner = rows.map { $0.2 + 4 }.max() ?? 0
        // Cadre seulement s'il tient dans l'écran ; sinon lignes simples (pas de cadre cassé par le retour à la ligne).
        if inner + 2 + indent.count <= columns {
            lines.append(indent + fg(dim) + "┌" + String(repeating: "─", count: inner) + "┐" + reset)
            for (mark, text, w) in rows {
                lines.append(indent + fg(dim) + "│" + reset + " " + fg(accent) + mark + reset + " " + text
                             + String(repeating: " ", count: inner - w - 3) + fg(dim) + "│" + reset)
            }
            lines.append(indent + fg(dim) + "└" + String(repeating: "─", count: inner) + "┘" + reset)
        } else {
            for (mark, text, _) in rows { lines.append(indent + fg(accent) + mark + reset + " " + text) }
        }
        lines.append("")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Largeur affichée : séquences CSI retirées, un caractère = une colonne (aucun caractère large utilisé ici).
    public static func visibleWidth(_ s: String) -> Int { stripANSI(s).count }

    public static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}
