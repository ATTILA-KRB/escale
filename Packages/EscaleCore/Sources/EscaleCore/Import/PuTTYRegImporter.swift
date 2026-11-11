import Foundation

/// Import des sessions PuTTY depuis un export `.reg` de `HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions`
/// (regedit : UTF-16LE avec BOM ; l'UTF-8 est aussi accepté).
///
/// Sources : documentation PuTTY (https://the.earth.li/~sgtatham/putty/latest/htmldoc/ : « Storing configuration in a file »,
/// « Port forwarding ») et `settings.c` de PuTTY (noms de valeurs, `PortForwardings`, nom de session échappé en `%XX`).
/// Valeurs lues : `HostName`, `PortNumber` (dword), `UserName`, `Protocol` (`ssh` ; absent = ssh ; `telnet` et `serial` aussi, `raw`
/// et `rlogin` sont ignorés avec un avertissement), `PublicKeyFile`,
/// `PortForwardings` (`L[adresse:]port=hôte:port`, `R…`, `D[adresse:]port`, séparés par des virgules), `X11Forward` (dword).
/// Série (settings.c de PuTTY, valeurs de putty.h) : `SerialLine` (`COM3`, `/dev/ttyUSB0`), `SerialSpeed` (bauds), `SerialDataBits`,
/// `SerialStopHalfbits` (2 = 1 bit, 3 = 1,5, 4 = 2), `SerialParity` (0 aucune, 1 impaire, 2 paire, 3 marque, 4 espace),
/// `SerialFlowControl` (0 aucun, 1 XON/XOFF, 2 RTS/CTS, 3 DSR/DTR). Sans équivalent : 1,5 arrêt → 1, marque/espace → aucune,
/// DSR/DTR → matériel (avertissement). Une ligne `COMx` n'existe pas sous macOS : `devicePath` vide + avertissement « choisir le port ».
/// Le nom de session est décodé (`My%20Server`) ; un `/` dans le nom (convention de dossiers de KiTTY/PuTTYCM) crée
/// des dossiers. « Default Settings » est ignoré.
/// `RemoteCommand` (« Remote command », Connection › SSH ; settings.c) → `startupCommand` (voir `StartupCommand` : PuTTY remplace
/// le shell par la commande, Escale la tape dans le shell qui reste ouvert ensuite).
/// `ProxyMethod` (dword, énumération de putty.h : 0 aucun, 1 SOCKS4, 2 SOCKS5, 3 HTTP, 4 Telnet, 5 Command, puis depuis PuTTY 0.77
/// 6 « SSH to proxy and use port forwarding », 7 « …execute a command », 8 « …invoke a subsystem » ; doc § 4.15 « SSH proxy »)
/// : seul 6 (équivalent de `ssh -J`) devient un `jumpHosts` (`ProxyHost`, `ProxyPort`, `ProxyUsername` ; si `ProxyHost` est le nom
/// d'une autre session du même fichier, son hôte/port/utilisateur sont repris) ; les autres types donnent un avertissement. Les mots de passe de proxy (`ProxyPassword`) sont comptés, jamais repris.
public struct PuTTYRegImporter: SessionImporter {
    public let sourceName = "PuTTY"
    public init() {}

    private static let sessionsPrefix = #"software\simontatham\putty\sessions\"#

    public func parse(text: String) -> SessionImportResult {
        var result = SessionImportResult()
        var currentName: String?
        var values: [String: String] = [:]
        var entries: [String: [String: String]] = [:]

        func flush() {
            if let n = currentName {
                entries[(n.removingPercentEncoding ?? n)] = values
                finish(name: n, values: values, into: &result)
            }
            currentName = nil; values = [:]
        }

        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                let key = String(line.dropFirst().dropLast(line.hasSuffix("]") ? 1 : 0))
                if let r = key.lowercased().range(of: Self.sessionsPrefix) {
                    // Les noms de session ne contiennent jamais `\` (échappé) : le reste est le nom.
                    let offset = key.lowercased().distance(from: key.lowercased().startIndex, to: r.upperBound)
                    let raw = String(key.dropFirst(offset))
                    if !raw.isEmpty, !raw.contains("\\") { currentName = raw }
                }
                continue
            }
            guard currentName != nil, line.hasPrefix("\"") else { continue }
            if let (k, v) = Self.value(line) { values[k] = v }
        }
        flush()
        resolveProxies(entries, into: &result)
        return result
    }

    /// Sauts SSH (`ProxyMethod` 6) et avertissements pour les autres proxys, une fois toutes les sessions lues.
    private func resolveProxies(_ entries: [String: [String: String]], into result: inout SessionImportResult) {
        for i in result.sessions.indices {
            let key = (result.sessions[i].folderPath + [result.sessions[i].name]).joined(separator: "/")
            guard let v = entries[key] else { continue }
            let method = (v["ProxyMethod"] ?? "0").lowercased()
            let name = result.sessions[i].name
            guard result.sessions[i].connectionProtocol == .ssh else {
                if method != "0", method != "none" {
                    result.warnings.append("« \(name) » : proxy PuTTY ignoré (session \(result.sessions[i].connectionProtocol.displayName), pas SSH).")
                }
                continue
            }
            if method == "0" || method == "none" { continue }
            guard method == "6" || method == "ssh" else {
                let label = ["1": "SOCKS4", "2": "SOCKS5", "3": "HTTP", "4": "Telnet", "5": "commande locale", "7": "SSH + commande", "8": "SSH + sous-système"][method] ?? "type \(method)"
                result.warnings.append("« \(name) » : proxy PuTTY (\(label)) sans équivalent ssh, ignoré (ajoutez un bastion à la main si besoin).")
                continue
            }
            var host = (v["ProxyHost"] ?? "").trimmingCharacters(in: .whitespaces)
            var port = ImportSupport.port(v["ProxyPort"])
            var user: String? = (v["ProxyUsername"] ?? "").isEmpty ? nil : v["ProxyUsername"]
            if let ref = entries[host], let h = ref["HostName"], !h.isEmpty {
                host = h.trimmingCharacters(in: .whitespaces)
                if let at = host.lastIndex(of: "@") { user = user ?? String(host[..<at]); host = String(host[host.index(after: at)...]) }
                port = ImportSupport.port(ref["PortNumber"]) ?? port
                if let u = ref["UserName"], !u.isEmpty { user = user ?? u }
            }
            guard !host.isEmpty else {
                result.warnings.append("« \(name) » : proxy SSH PuTTY sans hôte, ignoré.")
                continue
            }
            result.sessions[i].jumpHosts.append(ImportSupport.jump(host: host, port: port, user: user))
        }
    }

    private func finish(name rawName: String, values v: [String: String], into result: inout SessionImportResult) {
        let name = rawName.removingPercentEncoding ?? rawName
        if name == "Default Settings" { return }
        let proto = (v["Protocol"] ?? "ssh").lowercased()
        if proto == "serial" { serialSession(name: name, values: v, into: &result); return }
        guard proto == "ssh" || proto == "telnet" else {
            result.warnings.append("« \(name) » : protocole \(proto) non pris en charge, ignoré.")
            return
        }
        let isTelnet = proto == "telnet"
        if let p = v["ProxyPassword"], !p.isEmpty { result.ignoredPasswordCount += 1 }
        var host = (v["HostName"] ?? "").trimmingCharacters(in: .whitespaces)
        var user = (v["UserName"] ?? "").trimmingCharacters(in: .whitespaces)
        // PuTTY accepte « user@host » dans le champ hôte.
        if let at = host.lastIndex(of: "@") {
            if user.isEmpty { user = String(host[..<at]) }
            host = String(host[host.index(after: at)...])
        }
        guard !host.isEmpty else {
            result.warnings.append("« \(name) » : hôte vide, ignoré.")
            return
        }
        // Dossiers par convention « Dossier/Sous-dossier/Session ».
        var comps = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let display = comps.popLast() ?? name

        var port: Int?
        if let p = v["PortNumber"] { port = ImportSupport.port(p, protocol: isTelnet ? .telnet : .ssh) }
        if isTelnet {
            result.sessions.append(ImportedSession(
                name: display, host: host, port: port, user: user.isEmpty ? nil : user, folderPath: comps,
                connectionProtocol: .telnet))
            return
        }
        let auth = ImportSupport.auth(forKeyPath: v["PublicKeyFile"] ?? "", sessionName: name, warnings: &result.warnings)
        let tunnels = Self.tunnels(v["PortForwardings"] ?? "", sessionName: name, warnings: &result.warnings)
        result.sessions.append(ImportedSession(
            name: display, host: host, port: port, user: user.isEmpty ? nil : user, auth: auth,
            folderPath: comps, tunnels: tunnels, x11Forwarding: v["X11Forward"] == "1",
            startupCommand: StartupCommand.normalized(v["RemoteCommand"])))
    }

    /// Session série : `SerialLine`, `SerialSpeed`, `SerialDataBits`, `SerialStopHalfbits`, `SerialParity`, `SerialFlowControl`.
    private func serialSession(name rawName: String, values v: [String: String], into result: inout SessionImportResult) {
        let name = rawName
        var comps = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let display = comps.popLast() ?? name
        var s = SerialSettings()
        let line = (v["SerialLine"] ?? "").trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("/dev/") {
            s.devicePath = line
        } else {
            result.warnings.append("« \(name) » : port série PuTTY « \(line.isEmpty ? "inconnu" : line) » sans équivalent macOS, choisir le port (/dev/cu.…) après l'import.")
        }
        if let b = Int(v["SerialSpeed"] ?? ""), b > 0 { s.baudRate = b }
        if let d = Int(v["SerialDataBits"] ?? ""), (5...8).contains(d) { s.dataBits = d }
        switch v["SerialStopHalfbits"] ?? "2" {
        case "4": s.stopBits = 2
        case "3":
            result.warnings.append("« \(name) » : 1,5 bit d'arrêt sans équivalent, 1 bit utilisé.")
        default: break
        }
        switch v["SerialParity"] ?? "0" {
        case "1": s.parity = .odd
        case "2": s.parity = .even
        case "3", "4":
            result.warnings.append("« \(name) » : parité marque/espace sans équivalent, aucune parité utilisée.")
        default: break
        }
        switch v["SerialFlowControl"] ?? "0" {
        case "1": s.flowControl = .software
        case "2": s.flowControl = .hardware
        case "3":
            s.flowControl = .hardware
            result.warnings.append("« \(name) » : contrôle de flux DSR/DTR sans équivalent, matériel (RTS/CTS) utilisé.")
        default: break
        }
        result.sessions.append(ImportedSession(
            name: display, host: s.devicePath, folderPath: comps, connectionProtocol: .serial, serial: s))
    }

    // MARK: Lignes .reg

    /// `"Clé"="texte"` (échappements `\\` et `\"`) ou `"Clé"=dword:0000001a` (converti en décimal).
    static func value(_ line: String) -> (String, String)? {
        let chars = Array(line)
        var i = 1
        var key = ""
        while i < chars.count, chars[i] != "\"" { key.append(chars[i]); i += 1 }
        guard i < chars.count else { return nil }
        i += 1
        guard i < chars.count, chars[i] == "=" else { return nil }
        let rest = String(chars[(i + 1)...])
        if rest.hasPrefix("dword:") {
            guard let n = UInt32(rest.dropFirst(6), radix: 16) else { return nil }
            return (key, String(n))
        }
        guard rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 else { return nil }
        var out = ""
        var esc = false
        for c in rest.dropFirst().dropLast() {
            if esc { out.append(c); esc = false } else if c == "\\" { esc = true } else { out.append(c) }
        }
        return (key, out)
    }

    // MARK: Redirections

    static func tunnels(_ raw: String, sessionName: String, warnings: inout [String]) -> [TunnelSpec] {
        var out: [TunnelSpec] = []
        for item in raw.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !item.isEmpty {
            var s = Substring(item)
            // Préfixes de famille d'adresses (`4`, `6`) ou « tout » (`A`) avant le type.
            while let c = s.first, "46A".contains(c) { s = s.dropFirst() }
            guard let t = s.first, "LRD".contains(t) else {
                warnings.append("« \(sessionName) » : redirection « \(item) » non reconnue, ignorée.")
                continue
            }
            let kind: TunnelSpec.Kind = t == "L" ? .local : t == "R" ? .remote : .dynamic
            let body = s.dropFirst()
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let (bindAddr, bindPort) = hostPort(String(parts[0]))
            guard let bp = bindPort else {
                warnings.append("« \(sessionName) » : redirection « \(item) » sans port, ignorée.")
                continue
            }
            let bind = bindAddr.isEmpty ? "127.0.0.1" : bindAddr
            if kind == .dynamic {
                out.append(TunnelSpec(kind: .dynamic, bindAddress: bind, bindPort: bp))
                continue
            }
            let (dh, dp) = hostPort(parts.count > 1 ? String(parts[1]) : "")
            guard !dh.isEmpty, let dport = dp else {
                warnings.append("« \(sessionName) » : redirection « \(item) » sans destination, ignorée.")
                continue
            }
            out.append(TunnelSpec(kind: kind, bindAddress: bind, bindPort: bp, destinationHost: dh, destinationPort: dport))
        }
        return out
    }

    /// `[adresse:]port` ou `hôte:port` (dernier `:` ; crochets IPv6 retirés). Sans `:` : tout est le port.
    private static func hostPort(_ s: String) -> (String, Int?) {
        guard let colon = s.lastIndex(of: ":") else { return ("", Int(s)) }
        var h = String(s[..<colon])
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return (h, Int(s[s.index(after: colon)...]))
    }
}
