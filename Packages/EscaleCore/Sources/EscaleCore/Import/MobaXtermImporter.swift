import Foundation

/// Import des sessions SSH de MobaXterm : `.mxtsessions` (export, Windows-1252) ou `MobaXterm.ini` (sections `[Bookmarks*]`).
///
/// Format (non documenté par l'éditeur ; rétro-ingénierie publique, version 23.6) :
/// - https://github.com/gplv2/mobaxterm2ssh/blob/master/docs/mxtsessions_format.md (reprise du gist « .mxtsessions file
///   format » de Ruzgfpegk) ;
/// - https://github.com/ktsouvalis/mobaxterm-sessions (convertisseurs vers Remmina/PuTTY) ;
/// - exemples de lignes : https://github.com/fivedoumi/my_mobaxterm_conf/blob/master/MobaXterm.ini.
///
/// Structure : INI. `[Bookmarks]` (racine) puis `[Bookmarks_N]`, chacune avec `SubRep=Dossier\Sous-dossier` (séparateur
/// `\`) et `ImgNum=`, suivis d'une ligne par session : `Nom=#<icône>#<groupe>#<police…>#<mode>#<commentaire>#<couleur>`.
/// Le groupe principal est séparé par `%` ; pour une session SSH (type 0) :
/// 0 type · 1 hôte · 2 port · 3 utilisateur (`<default>` = celui de l'app) · 4 inconnu (vide ; certains générateurs y mettent
/// un mot de passe : jamais repris) · 5 X11 (`-1` actif) · 6 compression · 7 commande de connexion · 8/9/10 passerelles SSH
/// (hôtes/ports/utilisateurs séparés par `__PIPE__`) · 11 · 12 · 13 environnement distant · 14 clé privée
/// (`C:` écrit `_CurrentDrive_`) · 15 clés des passerelles.
/// Types non SSH (Telnet #98 type 1, RDP, VNC, FTP, SFTP, série…) : ignorés avec un avertissement.
/// Les tunnels de MobaXterm ne sont pas dans la ligne de session (outil « Tunneling » séparé) : non importés.
/// Les mots de passe sont chiffrés dans `[Passwords]` / `[Credentials]` : comptés, jamais lus.
public struct MobaXtermImporter: SessionImporter {
    public let sourceName = "MobaXterm"
    public init() {}

    public func parse(text: String) -> SessionImportResult {
        var result = SessionImportResult()
        var inBookmarks = false
        var inSecrets = false
        var folder: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                inBookmarks = section == "Bookmarks" || section.hasPrefix("Bookmarks_")
                inSecrets = section == "Passwords" || section == "Credentials"
                folder = []
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if inSecrets { if !key.isEmpty, !value.isEmpty { result.ignoredPasswordCount += 1 }; continue }
            guard inBookmarks else { continue }
            if key == "SubRep" {
                folder = value.split(separator: "\\").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                continue
            }
            if key == "ImgNum" { continue }
            session(name: key, value: value, folder: folder, into: &result)
        }
        return result
    }

    private func session(name: String, value: String, folder: [String], into result: inout SessionImportResult) {
        guard value.hasPrefix("#") || value.contains("#") else { return }
        let parts = value.components(separatedBy: "#")
        guard parts.count >= 3 else { return }
        let f = parts[2].components(separatedBy: "%")
        guard let type = Int(f[0]) else { return }
        guard type == 0 else {
            result.warnings.append("« \(name) » : type de session MobaXterm \(type) (icône \(parts[1])) non SSH, ignoré.")
            return
        }
        func field(_ i: Int) -> String { i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : "" }
        let host = field(1)
        guard !host.isEmpty else {
            result.warnings.append("« \(name) » : hôte vide, ignoré.")
            return
        }
        var user: String? = field(3)
        if user == "" || user == "<default>" { user = nil }
        if !field(4).isEmpty { result.ignoredPasswordCount += 1 }

        // Passerelles : listes parallèles séparées par __PIPE__.
        func list(_ i: Int) -> [String] { field(i).components(separatedBy: "__PIPE__") }
        var jumps: [String] = []
        let gwHosts = list(8)
        if !(gwHosts.count == 1 && gwHosts[0].isEmpty) {
            let ports = list(9), users = list(10)
            for (i, h) in gwHosts.enumerated() where !h.isEmpty {
                jumps.append(ImportSupport.jump(host: h, port: ImportSupport.port(i < ports.count ? ports[i] : nil),
                                                user: i < users.count && !users[i].isEmpty ? users[i] : nil))
            }
        }
        let auth = ImportSupport.auth(forKeyPath: field(14), sessionName: name, warnings: &result.warnings)
        result.sessions.append(ImportedSession(
            name: name.isEmpty ? host : name, host: host, port: ImportSupport.port(field(2)), user: user, auth: auth,
            jumpHosts: jumps, folderPath: folder, x11Forwarding: field(5) == "-1"))
    }
}
