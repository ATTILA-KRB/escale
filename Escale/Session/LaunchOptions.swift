import Foundation

/// Arguments de lancement (pour les tests et le débogage) :
/// - `--command <exécutable> [args...]` : tout ce qui suit est la commande d'un onglet local ;
/// - `--library <fichier.json>` : bibliothèque d'hôtes (sinon Application Support/Escale/library.json) ;
/// - `--ssh-option Clé=Valeur` (répétable), `--ssh-config <fichier>`, `--known-hosts <fichier>` ;
/// - `--selftest <dossier>` (scénario local) et `--selftest-ssh <dossier>` (scénario SSH).
struct LaunchOptions: Equatable {
    var command: [String]?
    var selftestDirectory: String?
    var selftestSSHDirectory: String?
    var libraryPath: String?
    var sshConfig: String?
    var knownHosts: String?
    var sshOptions: [String] = []
    /// `--selftest-auth <dossier>` : scénario d'authentification (askpass, dialogues, import, recherche).
    var selftestAuthDirectory: String?
    /// `--selftest-panes <dossier>` : scénario des panneaux scindés.
    var selftestPanesDirectory: String?
    /// `--ssh-config-import-source <fichier>` : source de l'import à la place de ~/.ssh/config (tests).
    var sshConfigImportSource: String?
    /// `--keychain-service <nom>` : service Keychain (tests : service unique, jamais celui de l'utilisateur).
    var keychainService: String?

    /// Toute autre option `--nom valeur` (répétable), pour les modules ajoutés après M1
    /// (`--selftest-sftp <dossier>`, `--selftest-tunnels <dossier>`…) : pas de cas à ajouter ici.
    var extra: [String: [String]] = [:]

    /// Dernière valeur de `--nom` (nil si absente).
    func value(_ name: String) -> String? { extra[name]?.last }

    var isSelfTest: Bool {
        selftestDirectory != nil || selftestSSHDirectory != nil || selftestAuthDirectory != nil
            || selftestPanesDirectory != nil || extra.keys.contains { $0.hasPrefix("selftest-") }
    }

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        func value() -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--command":
                let rest = Array(args[(i + 1)...])
                if !rest.isEmpty { o.command = rest }
                return o
            case "--selftest": o.selftestDirectory = value()
            case "--selftest-ssh": o.selftestSSHDirectory = value()
            case "--selftest-auth": o.selftestAuthDirectory = value()
            case "--selftest-panes": o.selftestPanesDirectory = value()
            case "--ssh-config-import-source": o.sshConfigImportSource = value()
            case "--keychain-service": o.keychainService = value()
            case "--library": o.libraryPath = value()
            case "--ssh-config": o.sshConfig = value()
            case "--known-hosts": o.knownHosts = value()
            case "--ssh-option": if let v = value() { o.sshOptions.append(v) }
            case let a where a.hasPrefix("--") && a.count > 2:
                if let v = value() { o.extra[String(a.dropFirst(2)), default: []].append(v) }
            default:
                break // arguments système (-NSDocumentRevisionsDebugMode…) ignorés
            }
            i += 1
        }
        return o
    }
}
