import Foundation

/// Problème détecté sur une macro : une erreur bloque l'enregistrement, un avertissement informe.
public struct MacroIssue: Equatable, Sendable, Hashable {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public init(_ severity: Severity, _ message: String) { self.severity = severity; self.message = message }
}

/// Ensemble de macros et règles de cohérence (pur, sans entrée/sortie).
public struct MacroLibrary: Equatable, Sendable {
    public private(set) var macros: [Macro]

    public init(macros: [Macro] = []) { self.macros = macros }

    public mutating func upsert(_ macro: Macro) {
        if let i = macros.firstIndex(where: { $0.id == macro.id }) { macros[i] = macro } else { macros.append(macro) }
    }

    public mutating func remove(_ id: UUID) { macros.removeAll { $0.id == id } }

    /// Supprime les macros propres à un hôte supprimé.
    public mutating func removeMacros(forHost id: UUID) { macros.removeAll { $0.scope == .host(id) } }

    public mutating func move(from: Int, to: Int) {
        guard macros.indices.contains(from), macros.indices.contains(to), from != to else { return }
        macros.insert(macros.remove(at: from), at: to)
    }

    /// Macros proposées pour un hôte (globales + propres), dans l'ordre de la liste.
    public func macros(forHost hostID: UUID?) -> [Macro] { macros.filter { $0.applies(toHost: hostID) } }

    /// Macro liée à ce raccourci pour cet hôte (la macro propre à l'hôte l'emporte sur la globale).
    public func macro(forShortcut n: Int, host hostID: UUID?) -> Macro? {
        let candidates = macros(forHost: hostID).filter { $0.shortcut == n }
        return candidates.first { $0.scope != .global } ?? candidates.first
    }

    /// Deux portées se recouvrent si l'une est globale ou si elles visent le même hôte.
    private static func overlap(_ a: MacroScope, _ b: MacroScope) -> Bool {
        switch (a, b) {
        case (.host(let x), .host(let y)): x == y
        default: true
        }
    }

    /// Vérifie une macro avant enregistrement.
    public func validate(_ macro: Macro) -> [MacroIssue] {
        var issues: [MacroIssue] = []
        if macro.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init(.error, "Le nom est vide.")) }
        if macro.steps.isEmpty { issues.append(.init(.error, "La macro n'a aucune étape.")) }
        if let s = macro.shortcut {
            if !Macro.shortcutRange.contains(s) {
                issues.append(.init(.error, "Raccourci invalide : \(s)."))
            } else if let other = macros.first(where: { $0.id != macro.id && $0.shortcut == s && Self.overlap($0.scope, macro.scope) }) {
                issues.append(.init(.error, "Le raccourci ⌃⌥\(s) est déjà pris par « \(other.name) »."))
            }
        }
        for step in macro.steps {
            if case .wait(let ms) = step, ms < 0 || ms > Macro.maxWaitMilliseconds {
                issues.append(.init(.error, "Attente hors limites : \(ms) ms (0 à \(Macro.maxWaitMilliseconds))."))
            }
        }
        issues += MacroSecretHeuristics.findings(in: macro).map { .init(.warning, $0) }
        return issues
    }
}

/// Repère les macros qui ressemblent à un mot de passe ou à un jeton : une macro est stockée en clair,
/// le Trousseau est le seul endroit des secrets (invariant 7). Heuristique : avertit, ne bloque pas.
public enum MacroSecretHeuristics {
    private static let patterns: [(String, String)] = [
        (#"(?i)\b(pass(word|wd)?|mdp|motdepasse|secret|token|api[_-]?key)\s*[=:]\s*\S+"#, "contient « mot de passe / jeton = valeur »"),
        (#"(?i)\bsshpass\b"#, "utilise sshpass (mot de passe en clair)"),
        (#"(?i)\b(echo|printf)\b[^|\n]*\|\s*sudo\s+-S"#, "envoie un mot de passe à sudo -S"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._\-]{12,}"#, "contient un jeton Bearer"),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "contient une clé privée"),
        (#"\b(AKIA|ASIA)[A-Z0-9]{16}\b"#, "ressemble à une clé d'accès AWS"),
        (#"(?i)\b(mysql|psql|mongo)\b.*\s-p\S+"#, "mot de passe passé en argument (-p…)"),
        (#"(?i)://[^/\s:@]+:[^/\s@]+@"#, "URL avec identifiants (utilisateur:mot-de-passe@)"),
    ]

    /// Phrases d'avertissement (dédoublonnées, ordre stable).
    public static func findings(in macro: Macro) -> [String] {
        var out: [String] = []
        let text = macro.steps.compactMap { step -> String? in if case .text(let t) = step { t } else { nil } }.joined(separator: "\n")
        let range = NSRange(text.startIndex..., in: text)
        for (pattern, why) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            if re.firstMatch(in: text, range: range) != nil { out.append("Cette macro \(why) : elle est enregistrée en clair, ne la gardez pas.") }
        }
        // Texte court et isolé juste après une attente : schéma typique d'une invite de mot de passe tapée à l'aveugle.
        for (i, step) in macro.steps.enumerated() where i > 0 {
            if case .wait = macro.steps[i - 1], case .text(let t) = step {
                let word = t.trimmingCharacters(in: .newlines)
                if t.hasSuffix("\n"), !word.isEmpty, !word.contains(" "), word.count >= 6, word.count <= 40,
                   word.rangeOfCharacter(from: .decimalDigits) != nil, word.rangeOfCharacter(from: .letters) != nil,
                   !word.contains("/"), !word.contains("-"), !word.contains(".") {
                    out.append("Une étape après une attente ressemble à un mot de passe saisi à une invite : ne l'enregistrez pas dans une macro.")
                    break
                }
            }
        }
        return out
    }
}
