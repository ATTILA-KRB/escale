import Foundation

/// Validation d'un tunnel saisi par l'utilisateur (ports, adresses) et avertissements non bloquants.
public enum TunnelValidation {
    /// Erreurs bloquantes (vide : le tunnel est utilisable). Messages en français, prêts pour l'interface.
    public static func errors(_ t: TunnelSpec) -> [String] {
        var e: [String] = []
        if t.kind == .remote {
            if !(0...65535).contains(t.bindPort) { e.append("Le port d'écoute doit être compris entre 0 et 65535 (0 : le serveur choisit).") }
        } else if !(1...65535).contains(t.bindPort) {
            e.append("Le port d'écoute doit être compris entre 1 et 65535.")
        }
        if let m = addressProblem(t.bindAddress, allowEmpty: true, allowWildcard: true, label: "L'adresse d'écoute") { e.append(m) }
        if t.kind != .dynamic {
            if t.destinationHost.trimmingCharacters(in: .whitespaces).isEmpty {
                e.append("L'hôte de destination est obligatoire.")
            } else if let m = addressProblem(t.destinationHost, allowEmpty: false, allowWildcard: false, label: "L'hôte de destination") {
                e.append(m)
            }
            if !(1...65535).contains(t.destinationPort) { e.append("Le port de destination doit être compris entre 1 et 65535.") }
        }
        return e
    }

    /// Avertissements : le tunnel fonctionne, mais l'utilisateur doit le savoir.
    public static func warnings(_ t: TunnelSpec) -> [String] {
        var w: [String] = []
        if t.kind == .remote, t.bindPort == 0 {
            w.append("Port 0 : le serveur attribue le port d'écoute à l'ouverture ; il sera affiché dans le gestionnaire.")
        }
        if !isLoopback(t.bindAddress) {
            switch t.kind {
            case .remote:
                w.append("Écoute sur « \(displayBind(t.bindAddress)) » côté serveur : exige GatewayPorts sur le serveur, et expose le port au réseau du serveur.")
            default:
                w.append("Écoute sur « \(displayBind(t.bindAddress)) » : le tunnel sera accessible depuis le réseau, pas seulement depuis ce Mac.")
            }
        }
        if t.kind != .remote, (1..<1024).contains(t.bindPort) {
            w.append("Le port \(t.bindPort) est privilégié : l'ouverture échouera sans droits administrateur.")
        }
        return w
    }

    /// Erreurs de cohérence d'une liste (deux tunnels qui écoutent sur la même adresse et le même port).
    public static func listErrors(_ tunnels: [TunnelSpec]) -> [String] {
        var seen: [String: String] = [:]
        var out: [String] = []
        for t in tunnels {
            let side = t.kind == .remote ? "R" : "L"
            let key = "\(side)|\(normalizedBind(t.bindAddress))|\(t.bindPort)"
            if let first = seen[key] {
                out.append("Deux tunnels écoutent sur le même port \(t.bindPort) (« \(first) » et « \(t.title) »).")
            } else { seen[key] = t.title }
        }
        return out
    }

    public static func isLoopback(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        return a.isEmpty || a == "localhost" || a == "127.0.0.1" || a.hasPrefix("127.") || a == "::1" || a == "[::1]"
    }

    /// Vrai pour une adresse IPv6 littérale valide, avec ou sans crochets (`::1`, `[2001:db8::1]`). Zones `%en0` refusées.
    public static func isIPv6(_ address: String) -> Bool {
        var a = in6_addr()
        return inet_pton(AF_INET6, TunnelSpec.unbracketed(address), &a) == 1
    }

    /// Adresse affichable/utilisable dans une URL : l'adresse générique devient 127.0.0.1.
    public static func displayBind(_ address: String) -> String {
        let a = TunnelSpec.unbracketed(address.trimmingCharacters(in: .whitespaces))
        if a == "::" { return "::1" }
        return (a.isEmpty || a == "*" || a == "0.0.0.0") ? "127.0.0.1" : a
    }

    static func canonicalAddress(_ a: String) -> String { normalizedBind(a) }

    private static func normalizedBind(_ a: String) -> String {
        let t = a.trimmingCharacters(in: .whitespaces).lowercased()
        if isIPv6(t) { // forme canonique : `::1` et `0:0:0:0:0:0:0:1` désignent la même adresse
            var addr = in6_addr(); var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_pton(AF_INET6, TunnelSpec.unbracketed(t), &addr) == 1, inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil {
                return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return (t.isEmpty || t == "localhost") ? "127.0.0.1" : t
    }

    private static func addressProblem(_ s: String, allowEmpty: Bool, allowWildcard: Bool, label: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return allowEmpty ? nil : "\(label) est obligatoire." }
        if t == "*" { return allowWildcard ? nil : "\(label) ne peut pas être « * »." }
        if t != s { return "\(label) contient des espaces." }
        // IPv6 littérale : saisie avec ou sans crochets (`::1`, `[::1]`) ; ssh reçoit toujours la forme à crochets.
        if t.contains(":") || t.hasPrefix("[") || t.hasSuffix("]") {
            return isIPv6(t) ? nil : "\(label) : adresse IPv6 non valide (zones « %interface » non prises en charge)."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        if t.unicodeScalars.contains(where: { !allowed.contains($0) }) { return "\(label) contient des caractères non valides." }
        if t.hasPrefix("-") { return "\(label) ne peut pas commencer par un tiret." }
        return nil
    }
}

extension TunnelSpec {
    /// Libellé court : le nom s'il existe, sinon la description « L 8080 → hôte:80 ».
    public var title: String { name.isEmpty ? summary : name }

    /// Description compacte du tunnel, sans le nom.
    public var summary: String {
        switch kind {
        case .local: "Local \(Self.bracketed(bindAddress)):\(bindPort) → \(Self.bracketed(destinationHost)):\(destinationPort)"
        case .remote: "Distant \(Self.bracketed(bindAddress)):\(bindPort == 0 ? "auto" : String(bindPort)) → \(Self.bracketed(destinationHost)):\(destinationPort)"
        case .dynamic: "SOCKS \(Self.bracketed(bindAddress)):\(bindPort)"
        }
    }

    /// URL à copier : `http://127.0.0.1:port` (L, et R vu du serveur), `socks5://127.0.0.1:port` (D).
    public var clientURL: String {
        let host = Self.bracketed(TunnelValidation.displayBind(bindAddress))
        return kind == .dynamic ? "socks5://\(host):\(bindPort)" : "http://\(host):\(bindPort)"
    }

    /// Même redirection (type, adresses, ports) : le nom et `autoStart` ne comptent pas. Sert à décider d'un remplacement à chaud.
    public func sameForwarding(as other: TunnelSpec) -> Bool {
        kind == other.kind && bindPort == other.bindPort
            && TunnelValidation.canonicalAddress(bindAddress) == TunnelValidation.canonicalAddress(other.bindAddress)
            && (kind == .dynamic || (destinationPort == other.destinationPort
                && TunnelValidation.canonicalAddress(destinationHost) == TunnelValidation.canonicalAddress(other.destinationHost)))
    }
}
