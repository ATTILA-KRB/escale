import Foundation

/// Arguments de lancement (pour les tests et le débogage) :
/// - `--command <exécutable> [args...]` : tout ce qui suit est la commande d'un onglet local ;
/// - `--library <fichier.json>` : bibliothèque d'hôtes (sinon Application Support/Escale/hosts.json) ;
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

    var isSelfTest: Bool { selftestDirectory != nil || selftestSSHDirectory != nil }

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
            case "--library": o.libraryPath = value()
            case "--ssh-config": o.sshConfig = value()
            case "--known-hosts": o.knownHosts = value()
            case "--ssh-option": if let v = value() { o.sshOptions.append(v) }
            default:
                break // arguments système (-NSDocumentRevisionsDebugMode…) ignorés
            }
            i += 1
        }
        return o
    }
}
