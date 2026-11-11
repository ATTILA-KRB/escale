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
/// Autres types de session (champ 0 ; icône par défaut entre parenthèses ; table « Default icons per session type » du même
/// document et `parse_bookmarks` de Metasploit, modules/post/windows/gather/credentials/moba_xterm.rb, qui associe
/// `#109#0` ssh · `#98#1` telnet · `#100#2` rsh · `#91#4` rdp · `#128#5` vnc · `#130#6` ftp · `#140#7` sftp) :
/// - 1 Telnet (98) : 1 hôte · 2 port · 3 utilisateur (gabarit du convertisseur Xshell→MobaXterm,
///   https://gist.github.com/findix/0625591aa6d3452d2d5ea124de34d97c, `#98#1%hôte%port%%%2…`) → `.telnet` ;
/// - 4 RDP (91) : 1 hôte · 2 port (3389) · 3 utilisateur (tableau « RDP Session lines » du document) → `.rdp` ;
/// - 5 VNC (128) : 1 hôte · 2 port (5900), pas d'utilisateur ; 5/6/7 = passerelle SSH, non reprise (tableau « VNC Session
///   lines ») → `.vnc` ;
/// - 8 Série (131) : format NON documenté par l'éditeur ni par le document ci-dessus ; déduit de deux lignes publiques :
///   `#131#8%1%1115200%3%0%0%1%2%COM9 (USB Serial Port (COM9))#…` (https://superuser.com/questions/1873359, session réelle
///   d'une version 23.x) et le gabarit du convertisseur Xshell (`#131#8%-2%100{vitesse}%3%0%0%1%2%{port}#…`, gist ci-dessus,
///   où `100`+`9600` donne `1009600`). Champ 2 = 1 000 000 + débit (1115200 → 115200 bauds ; 1009600 → 9600), champ 8 = port
///   (`COMx`). Les positions des bits de données, parité, arrêt et contrôle de flux n'ont pas de source : valeurs par défaut
///   d'Escale (8N1, sans contrôle de flux) et avertissement. Un port `COMx` n'a pas d'équivalent macOS : `devicePath` vide +
///   avertissement « choisir le port » ; un chemin `/dev/…` est repris tel quel ;
/// - tout le reste (Rsh, Xdmcp, FTP, SFTP, fichier, shell, navigateur, Mosh, S3, WSL…) : ignoré avec un avertissement.
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
        func field(_ i: Int) -> String { i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : "" }
        guard type == 0 else {
            switch type {
            case 1: networkSession(.telnet, name: name, field: field, folder: folder, into: &result)
            case 4: networkSession(.rdp, name: name, field: field, folder: folder, into: &result)
            case 5: networkSession(.vnc, name: name, field: field, folder: folder, into: &result)
            case 8: serialSession(name: name, field: field, folder: folder, into: &result)
            default:
                result.warnings.append("« \(name) » : type de session MobaXterm \(type) (icône \(parts[1])) non pris en charge, ignoré.")
            }
            return
        }
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

    /// Telnet, RDP, VNC : hôte (1), port (2), utilisateur (3, sauf VNC). `<default>` = utilisateur de l'application.
    private func networkSession(_ proto: ConnectionProtocol, name: String, field: (Int) -> String, folder: [String],
                                into result: inout SessionImportResult) {
        let host = field(1)
        guard !host.isEmpty else {
            result.warnings.append("« \(name) » : hôte vide, ignoré.")
            return
        }
        var user: String? = proto == .vnc ? nil : field(3)
        if user == "" || user == "<default>" { user = nil }
        if proto == .vnc, !field(5).isEmpty {
            result.warnings.append("« \(name) » : passerelle SSH VNC (\(field(5))) non reprise, ajoutez un tunnel à la main si besoin.")
        }
        result.sessions.append(ImportedSession(
            name: name.isEmpty ? host : name, host: host, port: ImportSupport.port(field(2), protocol: proto), user: user,
            folderPath: folder, connectionProtocol: proto))
    }

    /// Série : débit (champ 2, 1 000 000 + débit), port (champ 8). Voir l'en-tête du fichier pour les sources.
    private func serialSession(name: String, field: (Int) -> String, folder: [String], into result: inout SessionImportResult) {
        let rawPort = field(8)
        var settings = SerialSettings()
        if let code = Int(field(2)) {
            let baud = code >= 1_000_000 ? code - 1_000_000 : code
            if baud > 0 { settings.baudRate = baud }
        }
        if rawPort.hasPrefix("/dev/") {
            settings.devicePath = rawPort
        } else {
            let shown = rawPort.isEmpty ? "port inconnu" : rawPort
            result.warnings.append("« \(name) » : port série MobaXterm « \(shown) » sans équivalent macOS, choisir le port (/dev/cu.…) après l'import.")
        }
        result.warnings.append("« \(name) » : bits de données, parité, arrêt et contrôle de flux non lus dans l'export MobaXterm (8N1 sans contrôle de flux par défaut, à vérifier).")
        result.sessions.append(ImportedSession(
            name: name.isEmpty ? (rawPort.isEmpty ? "Série" : rawPort) : name, host: settings.devicePath, folderPath: folder,
            connectionProtocol: .serial, serial: settings))
    }
}
