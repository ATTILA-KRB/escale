import Foundation

/// Import générique depuis un CSV (UTF-8 ou UTF-16 avec BOM, sinon Windows-1252).
///
/// Première ligne = en-têtes (insensibles à la casse) : `name`, `host`, `port`, `user`, `folder`, `tags`.
/// Seule `host` est obligatoire ; `name` vaut `host` si absent. Alias acceptés : `nom`, `hostname`/`hôte`/`address`,
/// `username`/`utilisateur`, `dossier`/`group`/`groupe`, `étiquettes`/`tag`.
/// Séparateur détecté sur l'en-tête : `,`, `;` ou tabulation ; guillemets doubles RFC 4180 (`""`, retours à la ligne).
/// `folder` : chemin séparé par `/` ou `\` (ex. `Production/Web`). `tags` : séparés par `;`, `,` ou `|`
/// (celui qui n'est pas le séparateur de colonnes). Une colonne `password`/`motdepasse` est ignorée et comptée.
public struct CSVSessionImporter: SessionImporter {
    public let sourceName = "CSV"
    public init() {}

    public func parse(text: String) -> SessionImportResult {
        var result = SessionImportResult()
        let rows = Self.rows(text)
        guard let header = rows.first else { return result }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ aliases: [String]) -> Int? { names.firstIndex { aliases.contains($0) } }
        guard let hostCol = col(["host", "hostname", "hôte", "hote", "address", "adresse"]) else {
            result.warnings.append("Colonne « host » introuvable dans la première ligne du CSV.")
            return result
        }
        let nameCol = col(["name", "nom"]), portCol = col(["port"]), userCol = col(["user", "username", "utilisateur"])
        let folderCol = col(["folder", "dossier", "group", "groupe"]), tagsCol = col(["tags", "tag", "étiquettes", "etiquettes"])
        let pwdCol = col(["password", "motdepasse", "mot de passe", "pass"])
        let delimiter = Self.delimiter(of: text)
        let tagSeparators = CharacterSet(charactersIn: ",;|").subtracting(CharacterSet(charactersIn: String(delimiter)))

        for (n, row) in rows.dropFirst().enumerated() {
            let line = n + 2
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            if !cell(pwdCol).isEmpty { result.ignoredPasswordCount += 1 }
            let host = cell(hostCol)
            guard !host.isEmpty else {
                result.warnings.append("Ligne \(line) : hôte vide, ignorée.")
                continue
            }
            var port: Int?
            if !cell(portCol).isEmpty {
                port = ImportSupport.port(cell(portCol))
                if port == nil, Int(cell(portCol)) != 22 {
                    result.warnings.append("Ligne \(line) : port « \(cell(portCol)) » invalide, port par défaut utilisé.")
                }
            }
            let name = cell(nameCol)
            let user = cell(userCol)
            result.sessions.append(ImportedSession(
                name: name.isEmpty ? host : name, host: host, port: port, user: user.isEmpty ? nil : user,
                tags: cell(tagsCol).components(separatedBy: tagSeparators)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                folderPath: cell(folderCol).split(whereSeparator: { $0 == "/" || $0 == "\\" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        }
        return result
    }

    static func delimiter(of text: String) -> Character {
        let first = text.prefix { !$0.isNewline }
        let counts: [(Character, Int)] = [",", ";", "\t"].map { c in (c, first.filter { $0 == c }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// Analyse RFC 4180 (le séparateur est détecté sur la première ligne).
    static func rows(_ text: String) -> [[String]] {
        let d = delimiter(of: text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var i = 0
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"", field.isEmpty { quoted = true
            } else if c == d { endField()
            } else if c == "\n" { endRow()
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
