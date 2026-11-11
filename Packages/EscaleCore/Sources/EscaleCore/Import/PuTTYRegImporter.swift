import Foundation

/// Import des sessions PuTTY depuis un export `.reg` de `HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions`
/// (regedit : UTF-16LE avec BOM ; l'UTF-8 est aussi accepté).
///
/// Sources : documentation PuTTY (https://the.earth.li/~sgtatham/putty/latest/htmldoc/ : « Storing configuration in a file »,
/// « Port forwarding ») et `settings.c` de PuTTY (noms de valeurs, `PortForwardings`, nom de session échappé en `%XX`).
/// Valeurs lues : `HostName`, `PortNumber` (dword), `UserName`, `Protocol` (seul `ssh` ; absent = ssh), `PublicKeyFile`,
/// `PortForwardings` (`L[adresse:]port=hôte:port`, `R…`, `D[adresse:]port`, séparés par des virgules), `X11Forward` (dword).
/// Le nom de session est décodé (`My%20Server`) ; un `/` dans le nom (convention de dossiers de KiTTY/PuTTYCM) crée
/// des dossiers. « Default Settings » est ignoré. Les mots de passe de proxy (`ProxyPassword`) sont comptés, jamais repris.
public struct PuTTYRegImporter: SessionImporter {
    public let sourceName = "PuTTY"
    public init() {}

    private static let sessionsPrefix = #"software\simontatham\putty\sessions\"#

    public func parse(text: String) -> SessionImportResult {
        var result = SessionImportResult()
        var currentName: String?
        var values: [String: String] = [:]

        func flush() {
            if let n = currentName { finish(name: n, values: values, into: &result) }
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
        return result
    }

    private func finish(name rawName: String, values v: [String: String], into result: inout SessionImportResult) {
        let name = rawName.removingPercentEncoding ?? rawName
        if name == "Default Settings" { return }
        let proto = (v["Protocol"] ?? "ssh").lowercased()
        guard proto == "ssh" else {
            result.warnings.append("« \(name) » : protocole \(proto) non SSH, ignoré.")
            return
        }
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
        if let p = v["PortNumber"] { port = ImportSupport.port(p) }
        let auth = ImportSupport.auth(forKeyPath: v["PublicKeyFile"] ?? "", sessionName: name, warnings: &result.warnings)
        let tunnels = Self.tunnels(v["PortForwardings"] ?? "", sessionName: name, warnings: &result.warnings)
        result.sessions.append(ImportedSession(
            name: display, host: host, port: port, user: user.isEmpty ? nil : user, auth: auth,
            folderPath: comps, tunnels: tunnels, x11Forwarding: v["X11Forward"] == "1"))
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
