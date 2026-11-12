import Foundation

/// Cible saisie dans le champ « Connexion rapide » : `[ssh://][utilisateur@]hôte[:port]`, IPv6 entre crochets.
/// L'analyse est stricte : tout ce qui n'est pas un nom d'hôte, une adresse ou un alias plausible est refusé
/// (espace, caractère de contrôle, tiret initial qui serait lu comme une option par ssh).
public struct QuickConnectTarget: Hashable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user; self.host = host; self.port = port
    }

    /// Forme canonique affichée et utilisée comme nom d'hôte par défaut.
    public var display: String {
        var s = user.map { "\($0)@" } ?? ""
        s += host.contains(":") && port != nil ? "[\(host)]" : host
        if let port { s += ":\(port)" }
        return s
    }

    public static func parse(_ text: String) -> QuickConnectTarget? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("ssh://") { s = String(s.dropFirst(6)) }
        if s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, s.utf8.count <= 320 else { return nil }

        var user: String?
        if let at = s.lastIndex(of: "@") {
            let u = String(s[..<at])
            guard isValidUser(u) else { return nil }
            user = u
            s = String(s[s.index(after: at)...])
        }

        var host = s
        var port: Int?
        if s.hasPrefix("[") {
            // IPv6 entre crochets, port éventuel après.
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = parsePort(rest.dropFirst()) else { return nil }
                port = p
            }
            guard isValidIPv6(host) else { return nil }
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            guard let p = parsePort(s[s.index(after: colon)...]) else { return nil }
            port = p
            host = String(s[..<colon])
            guard isValidName(host) else { return nil }
        } else if s.contains(":") {
            // IPv6 nue (sans port).
            guard isValidIPv6(host) else { return nil }
        } else {
            guard isValidName(host) else { return nil }
        }
        return QuickConnectTarget(user: user, host: host, port: port)
    }

    /// Profil SSH correspondant (authentification laissée à OpenSSH).
    public func makeProfile() -> HostProfile {
        HostProfile(name: display, host: host, port: port, user: user)
    }

    /// Vrai si le profil désigne la même cible SSH (port 22 et port absent confondus).
    public func matches(_ profile: HostProfile) -> Bool {
        profile.connectionProtocol == .ssh && profile.host.lowercased() == host.lowercased()
            && profile.user == user && (profile.port ?? 22) == (port ?? 22)
    }

    private static func parsePort(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(s), (1...65535).contains(p) else { return nil }
        return p
    }

    private static let nameCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    private static func isValidName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && !s.hasPrefix("-") && !s.hasPrefix(".") && s.allSatisfy { nameCharacters.contains($0) }
    }

    private static func isValidUser(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && !s.hasPrefix("-")
            && s.allSatisfy { nameCharacters.contains($0) || $0 == "+" || $0 == "\\" || $0 == "$" }
    }

    /// Chiffres hexadécimaux, deux-points, points (forme mixte) et zone (`%en0`).
    private static func isValidIPv6(_ s: String) -> Bool {
        let parts = s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let addr = parts[0]
        guard addr.count >= 2, addr.count <= 45, addr.contains(":"),
              addr.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }) else { return false }
        if parts.count == 2 {
            let zone = parts[1]
            guard !zone.isEmpty, zone.count <= 16, zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        }
        return true
    }
}
