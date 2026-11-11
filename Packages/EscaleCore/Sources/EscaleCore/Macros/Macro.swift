import Foundation

/// Touche spéciale rejouable (séquences xterm en mode normal du curseur).
public enum MacroKey: String, Codable, CaseIterable, Sendable, Hashable {
    case tab, escape, backspace, delete
    case up, down, left, right, home, end, pageUp, pageDown
    case ctrlA, ctrlC, ctrlD, ctrlE, ctrlK, ctrlL, ctrlR, ctrlU, ctrlW, ctrlZ

    /// Octets envoyés au terminal pour cette touche.
    public var bytes: [UInt8] {
        switch self {
        case .tab: [0x09]
        case .escape: [0x1b]
        case .backspace: [0x7f]
        case .delete: [0x1b, 0x5b, 0x33, 0x7e]
        case .up: [0x1b, 0x5b, 0x41]
        case .down: [0x1b, 0x5b, 0x42]
        case .right: [0x1b, 0x5b, 0x43]
        case .left: [0x1b, 0x5b, 0x44]
        case .home: [0x1b, 0x5b, 0x48]
        case .end: [0x1b, 0x5b, 0x46]
        case .pageUp: [0x1b, 0x5b, 0x35, 0x7e]
        case .pageDown: [0x1b, 0x5b, 0x36, 0x7e]
        case .ctrlA: [0x01]
        case .ctrlC: [0x03]
        case .ctrlD: [0x04]
        case .ctrlE: [0x05]
        case .ctrlK: [0x0b]
        case .ctrlL: [0x0c]
        case .ctrlR: [0x12]
        case .ctrlU: [0x15]
        case .ctrlW: [0x17]
        case .ctrlZ: [0x1a]
        }
    }

    /// Libellé français pour l'éditeur.
    public var label: String {
        switch self {
        case .tab: "Tabulation"
        case .escape: "Échap"
        case .backspace: "Retour arrière"
        case .delete: "Suppr"
        case .up: "Flèche haut"
        case .down: "Flèche bas"
        case .left: "Flèche gauche"
        case .right: "Flèche droite"
        case .home: "Début"
        case .end: "Fin"
        case .pageUp: "Page précédente"
        case .pageDown: "Page suivante"
        case .ctrlA: "Ctrl-A"
        case .ctrlC: "Ctrl-C"
        case .ctrlD: "Ctrl-D"
        case .ctrlE: "Ctrl-E"
        case .ctrlK: "Ctrl-K"
        case .ctrlL: "Ctrl-L"
        case .ctrlR: "Ctrl-R"
        case .ctrlU: "Ctrl-U"
        case .ctrlW: "Ctrl-W"
        case .ctrlZ: "Ctrl-Z"
        }
    }
}

/// Une étape d'une macro.
public enum MacroStep: Hashable, Sendable {
    /// Texte envoyé tel quel ; chaque `\n` est envoyé comme la touche Entrée (retour chariot).
    case text(String)
    /// Attente en millisecondes avant l'étape suivante.
    case wait(milliseconds: Int)
    case key(MacroKey)
}

extension MacroStep: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, milliseconds, key }
    private enum Kind: String, Codable { case text, wait, key }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        case .wait: self = .wait(milliseconds: try c.decode(Int.self, forKey: .milliseconds))
        case .key: self = .key(try c.decode(MacroKey.self, forKey: .key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t): try c.encode(Kind.text, forKey: .type); try c.encode(t, forKey: .text)
        case .wait(let ms): try c.encode(Kind.wait, forKey: .type); try c.encode(ms, forKey: .milliseconds)
        case .key(let k): try c.encode(Kind.key, forKey: .type); try c.encode(k, forKey: .key)
        }
    }
}

/// Portée d'une macro : disponible partout ou pour un seul hôte.
public enum MacroScope: Hashable, Sendable {
    case global
    case host(UUID)
}

extension MacroScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, hostID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "host": self = .host(try c.decode(UUID.self, forKey: .hostID))
        default: self = .global
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global: try c.encode("global", forKey: .kind)
        case .host(let id): try c.encode("host", forKey: .kind); try c.encode(id, forKey: .hostID)
        }
    }
}

/// Séquence de saisie rejouable dans un terminal. Aucun secret : une macro est du texte en clair sur disque.
public struct Macro: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var steps: [MacroStep]
    /// Raccourci ⌃⌥1 à ⌃⌥9 (`nil` : aucun).
    public var shortcut: Int?
    public var scope: MacroScope

    public static let shortcutRange = 1...9
    /// Borne d'une attente (10 minutes) : au-delà, la macro ressemble à un blocage.
    public static let maxWaitMilliseconds = 600_000

    public init(id: UUID = UUID(), name: String, steps: [MacroStep] = [], shortcut: Int? = nil, scope: MacroScope = .global) {
        self.id = id; self.name = name; self.steps = steps; self.shortcut = shortcut; self.scope = scope
    }

    /// Vrai si la macro est proposée pour cet hôte (`nil` : terminal local, seules les globales).
    public func applies(toHost hostID: UUID?) -> Bool {
        switch scope {
        case .global: true
        case .host(let id): id == hostID
        }
    }

    /// Résumé d'une ligne (liste du gestionnaire).
    public var summary: String {
        steps.map { step -> String in
            switch step {
            case .text(let t): "“" + t.replacingOccurrences(of: "\n", with: "⏎") + "”"
            case .wait(let ms): "⏱ \(ms) ms"
            case .key(let k): "⌨ \(k.label)"
            }
        }.joined(separator: "  ")
    }
}
