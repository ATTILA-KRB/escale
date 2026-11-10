import Foundation

/// Nature d'une invite posée par ssh (déduite du texte passé en argv[1] à l'exécutable askpass).
public enum AskpassPromptKind: Sendable, Equatable {
    /// `user@host's password:` ou invite clavier-interactif « Password: ».
    case password(userAtHost: String?)
    /// `Enter passphrase for key '<chemin>':`
    case passphrase(keyPath: String)
    /// Invite clavier-interactif autre que le mot de passe (code de vérification, OTP, jeton…).
    case verificationCode(label: String)
    /// Clé d'hôte inconnue : ssh demande de confirmer (`yes`/`no`).
    case hostKeyConfirmation(keyType: String?, fingerprint: String?, host: String?)
    /// Clé d'hôte MODIFIÉE (ou divergente de celle de l'IP) : toujours refusée, jamais soumise à l'UI.
    case hostKeyChanged
    case other
}

/// Demande soumise à un `AskpassResponder`.
public struct AskpassRequest: Sendable, Equatable {
    public var kind: AskpassPromptKind
    /// Texte exact de l'invite (pour l'affichage). Peut contenir le chemin d'une clé, jamais de secret.
    public var text: String
    /// 1 la première fois que cette invite exacte est posée pendant la connexion, 2 au second passage (= secret refusé), etc.
    public var attempt: Int

    public init(kind: AskpassPromptKind, text: String, attempt: Int = 1) {
        self.kind = kind; self.text = text; self.attempt = attempt
    }
}

/// Réponse à une invite.
public enum AskpassDecision: Sendable, Equatable {
    /// Envoie ce secret à ssh. `remember` : proposition de mémorisation, honorée seulement après une connexion réussie.
    case secret(Secret, remember: Bool)
    /// Confirme une clé d'hôte inconnue (ssh reçoit `yes`).
    case accept
    /// Refus / annulation : l'exécutable askpass sort en erreur sans rien écrire.
    case cancel
}

/// Résout les invites de ssh. Implémenté par l'app (feuille de dialogue) ou par `StoredSecretResponder`.
public protocol AskpassResponder: Sendable {
    func respond(to request: AskpassRequest) async -> AskpassDecision
    /// Appelé par le transport une fois la connexion maître établie (moment sûr pour mémoriser un secret).
    func authenticationSucceeded() async
    /// Appelé par le transport quand la connexion échoue (les secrets en attente de mémorisation sont oubliés).
    func authenticationFailed() async
}

public extension AskpassResponder {
    func authenticationSucceeded() async {}
    func authenticationFailed() async {}
}

/// Classe une invite ssh d'après son texte. Textes de référence observés avec OpenSSH 10.3p1 : voir `AskpassPromptTests`.
public enum AskpassPromptClassifier {
    public static func classify(_ rawText: String) -> AskpassPromptKind {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // Clé d'hôte modifiée : prioritaire sur toute demande de confirmation.
        if lower.contains("remote host identification has changed")
            || lower.contains("possible dns spoofing")
            || lower.contains("differs from the key for the ip address")
            || (lower.contains("host key for") && lower.contains("has changed"))
            || lower.contains("offending") && lower.contains("key in") {
            return .hostKeyChanged
        }
        if lower.contains("are you sure you want to continue connecting") || lower.contains("can't be established") {
            let fp = firstMatch(#"(\S+) key fingerprint is:? (\S+)"#, in: text, groups: 2)
            let host = firstMatch(#"authenticity of host '([^']+)'"#, in: text, groups: 1)
            return .hostKeyConfirmation(
                keyType: fp.first.map { $0 },
                fingerprint: fp.count > 1 ? fp[1].trimmingCharacters(in: CharacterSet(charactersIn: ".,;")) : nil,
                host: host.first)
        }
        if let m = firstMatch(#"^Enter passphrase for (?:key )?'(.*)':?\s*$"#, in: text, groups: 1).first {
            return .passphrase(keyPath: m)
        }
        if let m = firstMatch(#"^Enter passphrase for (?:key )?(\S.*?):?\s*$"#, in: text, groups: 1).first {
            return .passphrase(keyPath: m)
        }
        if let m = firstMatch(#"^(.+)'s password:?\s*$"#, in: text, groups: 1).first {
            return .password(userAtHost: m)
        }
        // Clavier-interactif : `(user@host) <invite>` (ssh préfixe l'invite du serveur) ; « Password: » = vrai mot de passe.
        let g = firstMatch(#"^\(([^)]*)\)\s*(.*)$"#, in: text, groups: 2)
        if g.count == 2 {
            let label = g[1].trimmingCharacters(in: .whitespaces)
            if label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": ")) == "password" {
                return .password(userAtHost: g[0])
            }
            return .verificationCode(label: label)
        }
        if lower.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) == "password" { return .password(userAtHost: nil) }
        return .other
    }

    /// Groupes capturés du premier match (tableau vide si pas de match). Mode multi-lignes inactif : `^`/`$` bornent le texte.
    private static func firstMatch(_ pattern: String, in text: String, groups: Int) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return [] }
        return (1...groups).compactMap { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}
