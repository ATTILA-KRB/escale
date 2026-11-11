import Foundation

/// Validation d'un tunnel saisi par l'utilisateur (ports, adresses) et avertissements non bloquants.
public enum TunnelValidation {
    /// Erreurs bloquantes (vide : le tunnel est utilisable). Messages en français, prêts pour l'interface.
    public static func errors(_ t: TunnelSpec) -> [String] {
        var e: [String] = []
        if !(1...65535).contains(t.bindPort) { e.append("Le port d'écoute doit être compris entre 1 et 65535.") }
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
        return a.isEmpty || a == "localhost" || a == "127.0.0.1" || a.hasPrefix("127.")
    }

    /// Adresse affichable/utilisable dans une URL : l'adresse générique devient 127.0.0.1.
    public static func displayBind(_ address: String) -> String {
        let a = address.trimmingCharacters(in: .whitespaces)
        return (a.isEmpty || a == "*" || a == "0.0.0.0") ? "127.0.0.1" : a
    }

    private static func normalizedBind(_ a: String) -> String {
        let t = a.trimmingCharacters(in: .whitespaces).lowercased()
        return (t.isEmpty || t == "localhost") ? "127.0.0.1" : t
    }

    private static func addressProblem(_ s: String, allowEmpty: Bool, allowWildcard: Bool, label: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return allowEmpty ? nil : "\(label) est obligatoire." }
        if t == "*" { return allowWildcard ? nil : "\(label) ne peut pas être « * »." }
        if t != s { return "\(label) contient des espaces." }
        // L'argument -L/-R/-D est découpé sur « : » : une adresse IPv6 n'y tient pas sans crochets (non pris en charge ici).
        if t.contains(":") { return "\(label) : IPv6 non pris en charge (utilisez un nom d'hôte ou une adresse IPv4)." }
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
        case .local: "Local \(bindAddress):\(bindPort) → \(destinationHost):\(destinationPort)"
        case .remote: "Distant \(bindAddress):\(bindPort) → \(destinationHost):\(destinationPort)"
        case .dynamic: "SOCKS \(bindAddress):\(bindPort)"
        }
    }

    /// URL à copier : `http://127.0.0.1:port` (L, et R vu du serveur), `socks5://127.0.0.1:port` (D).
    public var clientURL: String {
        let host = TunnelValidation.displayBind(bindAddress)
        return kind == .dynamic ? "socks5://\(host):\(bindPort)" : "http://\(host):\(bindPort)"
    }
}
