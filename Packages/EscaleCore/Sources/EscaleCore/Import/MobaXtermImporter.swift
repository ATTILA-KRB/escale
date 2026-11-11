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
/// Champ 7 « Execute command » → `HostProfile.startupCommand` (`;` écrit `__PTVIRG__`, `%` écrit `__PERCENT__` ;
/// source : même document, tableau « SSH Session lines », index 7). Sémantique : voir `StartupCommand`.
///
/// Tunnels (outil « MobaSSHTunnel », menu Tools › Tunneling ; https://blog.mobatek.net/post/ssh-tunnels-and-port-forwarding/ et
/// https://mobaxterm.mobatek.net/documentation.html §6.5 pour les champs de l'interface : Forwarded port, SSH server, SSH login,
/// SSH port, Remote server, Remote port, types Local/Remote/Dynamic). ATTENTION : Mobatek ne publie pas le format de stockage
/// des tunnels dans `MobaXterm.ini` et AUCUNE source publique de ce format n'a été trouvée (recherches web, dépôts de
/// conversion). Format SUPPOSÉ et non vérifié sur un vrai fichier : section `[SSH_Tunnels]` (aussi `[Tunnels]`,
/// `[MobaSSHTunnel]`, ou toute ligne dont la clé commence par `MobaSSHTunnel`), une ligne par tunnel
/// `Nom=…#type%portÉcouté%hôteDistant%portDistant%hôteSSH%portSSH%utilisateurSSH%…#…`, où `type` vaut `0`/`L` (local),
/// `1`/`R` (distant) ou `2`/`D` (dynamique). Un tunnel dont l'hôte SSH ne correspond à aucune session importée du même
/// fichier (hôte + port) est écarté avec un avertissement ; une ligne illisible aussi. À corriger dès qu'un vrai
/// `MobaXterm.ini` avec tunnels est disponible.
/// Les mots de passe sont chiffrés dans `[Passwords]` / `[Credentials]` : comptés, jamais lus.
public struct MobaXtermImporter: SessionImporter {
    public let sourceName = "MobaXterm"
    public init() {}

    public func parse(text: String) -> SessionImportResult {
        var result = SessionImportResult()
        var inBookmarks = false
        var inSecrets = false
        var inTunnels = false
        var folder: [String] = []
        var tunnelLines: [(name: String, value: String)] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                inBookmarks = section == "Bookmarks" || section.hasPrefix("Bookmarks_")
                inSecrets = section == "Passwords" || section == "Credentials"
                inTunnels = Self.tunnelSections.contains(section.lowercased())
                folder = []
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if inSecrets { if !key.isEmpty, !value.isEmpty { result.ignoredPasswordCount += 1 }; continue }
            if inTunnels || (!inBookmarks && key.lowercased().hasPrefix("mobasshtunnel")) {
                tunnelLines.append((key, value)); continue
            }
            guard inBookmarks else { continue }
            if key == "SubRep" {
                folder = value.split(separator: "\\").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                continue
            }
            if key == "ImgNum" { continue }
            session(name: key, value: value, folder: folder, into: &result)
        }
        attachTunnels(tunnelLines, into: &result)
        return result
    }

    private static let tunnelSections: Set<String> = ["ssh_tunnels", "sshtunnels", "tunnels", "mobasshtunnel"]

    /// Rattache chaque tunnel à la session SSH importée de même hôte et port (utilisateur identique de préférence).
    private func attachTunnels(_ lines: [(name: String, value: String)], into result: inout SessionImportResult) {
        for (name, value) in lines {
            guard let t = Self.parseTunnel(value) else {
                result.warnings.append("Tunnel MobaXterm « \(name) » : ligne illisible (format non reconnu), ignoré.")
                continue
            }
            let port = ImportSupport.port(t.sshPort) ?? 22
            let candidates = result.sessions.indices.filter {
                result.sessions[$0].host.lowercased() == t.sshHost.lowercased() && (result.sessions[$0].port ?? 22) == port
            }
            let match = candidates.first { !t.sshUser.isEmpty && result.sessions[$0].user == t.sshUser } ?? candidates.first
            guard let i = match else {
                result.warnings.append("Tunnel MobaXterm « \(name) » : aucune session SSH importée vers \(t.sshHost):\(port), ignoré.")
                continue
            }
            result.sessions[i].tunnels.append(t.spec)
        }
    }

    struct ParsedTunnel { var spec: TunnelSpec; var sshHost: String; var sshPort: String; var sshUser: String }

    /// Première liste `%` d'au moins 5 champs parmi les groupes `#` de la ligne (cf. format supposé en tête de fichier).
    static func parseTunnel(_ value: String) -> ParsedTunnel? {
        for group in value.components(separatedBy: "#") {
            let f = group.components(separatedBy: "%").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 5 else { continue }
            let kind: TunnelSpec.Kind
            switch f[0].lowercased() {
            case "0", "l", "local": kind = .local
            case "1", "r", "remote": kind = .remote
            case "2", "d", "dynamic": kind = .dynamic
            default: continue
            }
            guard let bind = Int(f[1]), (1...65535).contains(bind) else { continue }
            func at(_ i: Int) -> String { i < f.count ? f[i] : "" }
            let sshHost = at(4)
            guard !sshHost.isEmpty else { continue }
            if kind == .dynamic {
                return ParsedTunnel(spec: TunnelSpec(kind: .dynamic, bindAddress: "127.0.0.1", bindPort: bind),
                                    sshHost: sshHost, sshPort: at(5), sshUser: at(6))
            }
            guard !at(2).isEmpty, let dport = Int(at(3)), (1...65535).contains(dport) else { continue }
            return ParsedTunnel(spec: TunnelSpec(kind: kind, bindAddress: "127.0.0.1", bindPort: bind,
                                                 destinationHost: at(2), destinationPort: dport),
                                sshHost: sshHost, sshPort: at(5), sshUser: at(6))
        }
        return nil
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
            jumpHosts: jumps, folderPath: folder, x11Forwarding: field(5) == "-1",
            startupCommand: StartupCommand.normalized(
                field(7).replacingOccurrences(of: "__PTVIRG__", with: ";").replacingOccurrences(of: "__PERCENT__", with: "%"))))
    }
}
