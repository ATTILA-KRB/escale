import Foundation

/// Arguments de lancement : `--command <exécutable> [args...]` (tout ce qui suit est la commande)
/// et `--selftest <dossier>` (scénario sans interaction humaine, écrit result.json + PNG).
struct LaunchOptions: Equatable {
    var command: [String]?
    var selftestDirectory: String?

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--command":
                let rest = Array(args[(i + 1)...])
                if !rest.isEmpty { o.command = rest }
                return o
            case "--selftest":
                if i + 1 < args.count { o.selftestDirectory = args[i + 1]; i += 1 }
            default:
                break // arguments système (-NSDocumentRevisionsDebugMode…) ignorés
            }
            i += 1
        }
        return o
    }
}
