import Foundation

/// Import des hôtes Termius depuis un CSV au format du modèle d'import de Termius.
///
/// Sources :
/// - documentation officielle « Import existing hosts » (https://docs.termius.com/getting-started/import-existing-hosts) et
///   « Importing CSV » (https://termius.com/documentation/importing-from-csv, https://support.termius.com/hc/en-us/articles/4402174294809) :
///   Termius importe des hôtes depuis un CSV avec libellés, adresses IP, protocoles, ports, groupes, sous-groupes, tags et
///   identifiants, d'après un modèle téléchargeable dans l'application ;
/// - colonnes du modèle, relevées dans des outils tiers qui l'écrivent ou le lisent :
///   `Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password`
///   (https://github.com/LXiuu/termius-data-exporter, https://wardterm.com/guides/import-ssh-config/,
///   https://morphgate.com/docs/import-hosts, https://termiyo.com/solutions/moving-from-termius/ : groupe imbriqué écrit
///   `Production/Web`, plusieurs tags dans une cellule `prod,web`, protocole `ssh`, `mosh` ou `telnet`, vide = SSH).
///
/// ATTENTION : Termius n'a PAS d'export de données natif (l'« Export » de l'application envoie une clé publique à un serveur) ;
/// ce CSV est donc celui qu'on écrit à la main ou que produisent des exporteurs communautaires. L'éditeur ne publie pas le
/// modèle en clair : les en-têtes sont reconnus sans tenir compte de la casse et avec quelques alias.
///
/// Règles : `Hostname/IP` obligatoire ; `Label` vaut l'hôte si vide ; `ssh`/vide → SSH, `telnet` → Telnet, `mosh` → SSH (avertissement) ;
/// les autres protocoles sont ignorés avec un avertissement. `Groups` → dossiers (séparateur `/`). La colonne `Password` est
/// ignorée et comptée (invariant 7) ; aucune clé n'est reprise (le CSV n'en porte pas).
public struct TermiusImporter: SessionImporter {
    public let sourceName = "Termius"
    public init() {}

    public func parse(text: String) -> SessionImportResult {
        var result = SessionImportResult()
        let rows = CSVSessionImporter.rows(text)
        guard let header = rows.first else { return result }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ aliases: [String]) -> Int? { names.firstIndex { aliases.contains($0) } }
        guard let hostCol = col(["hostname/ip", "hostname", "host", "ip", "address", "hostname / ip"]) else {
            result.warnings.append("Colonne « Hostname/IP » introuvable dans la première ligne du CSV Termius.")
            return result
        }
        let groupCol = col(["groups", "group"]), labelCol = col(["label", "name"]), tagsCol = col(["tags", "tag"])
        let protoCol = col(["protocol"]), portCol = col(["port"]), userCol = col(["username", "user", "login"])
        let pwdCol = col(["password"])

        for (n, row) in rows.dropFirst().enumerated() {
            let line = n + 2
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            if !cell(pwdCol).isEmpty { result.ignoredPasswordCount += 1 }
            let host = cell(hostCol)
            let label = cell(labelCol)
            let shown = label.isEmpty ? "ligne \(line)" : "« \(label) »"
            guard !host.isEmpty else {
                result.warnings.append("Ligne \(line) : hôte vide, ignorée.")
                continue
            }
            var proto = ConnectionProtocol.ssh
            switch cell(protoCol).lowercased() {
            case "", "ssh": break
            case "mosh":
                result.warnings.append("\(shown) : protocole Mosh importé en SSH.")
            case "telnet": proto = .telnet
            case let other:
                result.warnings.append("\(shown) : protocole \(other) non pris en charge, ignoré.")
                continue
            }
            var port: Int?
            if !cell(portCol).isEmpty {
                port = ImportSupport.port(cell(portCol), protocol: proto)
                if port == nil, Int(cell(portCol)) != proto.defaultPort {
                    result.warnings.append("Ligne \(line) : port « \(cell(portCol)) » invalide, port par défaut utilisé.")
                }
            }
            let user = cell(userCol)
            result.sessions.append(ImportedSession(
                name: label.isEmpty ? host : label, host: host, port: port, user: user.isEmpty ? nil : user,
                tags: cell(tagsCol).components(separatedBy: CharacterSet(charactersIn: ",;"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                folderPath: cell(groupCol).split(whereSeparator: { $0 == "/" || $0 == "\\" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                connectionProtocol: proto))
        }
        return result
    }
}
