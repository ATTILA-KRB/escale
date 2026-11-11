import Foundation

/// Un tunnel SSH. `specArgument` est la valeur passée à `-L`, `-R` ou `-D`.
public struct TunnelSpec: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case local, remote, dynamic

        public var flag: String {
            switch self {
            case .local: "-L"
            case .remote: "-R"
            case .dynamic: "-D"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var bindAddress: String
    public var bindPort: Int
    /// Ignorés pour `.dynamic`.
    public var destinationHost: String
    public var destinationPort: Int
    /// Libellé libre (vide : l'interface affiche `specArgument`).
    public var name: String
    /// Ouvert automatiquement à la connexion de l'hôte (et rétabli après reconnexion).
    public var autoStart: Bool

    public init(
        id: UUID = UUID(), kind: Kind, bindAddress: String = "127.0.0.1", bindPort: Int,
        destinationHost: String = "", destinationPort: Int = 0, name: String = "", autoStart: Bool = false
    ) {
        self.id = id; self.kind = kind; self.bindAddress = bindAddress; self.bindPort = bindPort
        self.destinationHost = destinationHost; self.destinationPort = destinationPort
        self.name = name; self.autoStart = autoStart
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, bindAddress, bindPort, destinationHost, destinationPort, name, autoStart
    }

    /// Décodage tolérant : `name` et `autoStart` ont une valeur par défaut.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        bindPort = try c.decode(Int.self, forKey: .bindPort)
        destinationHost = try c.decodeIfPresent(String.self, forKey: .destinationHost) ?? ""
        destinationPort = try c.decodeIfPresent(Int.self, forKey: .destinationPort) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    /// Valeur passée à `-L`/`-R`/`-D` (et à `-O forward|cancel`). Une adresse IPv6 est entourée de crochets
    /// (`[::1]:8080:[::1]:80`) : ssh découpe sur « : » et refuse `::1:8080:…`. `-R` accepte le port 0 (le serveur choisit).
    public var specArgument: String {
        let bind = Self.bracketed(bindAddress)
        switch kind {
        case .dynamic: return "\(bind):\(bindPort)"
        case .local, .remote: return "\(bind):\(bindPort):\(Self.bracketed(destinationHost)):\(destinationPort)"
        }
    }

    /// `::1` ou `[::1]` donne `[::1]` ; toute autre adresse est rendue telle quelle.
    public static func bracketed(_ address: String) -> String {
        let inner = unbracketed(address)
        return inner.contains(":") ? "[\(inner)]" : address
    }

    /// `[::1]` donne `::1`.
    public static func unbracketed(_ address: String) -> String {
        address.hasPrefix("[") && address.hasSuffix("]") && address.count >= 2 ? String(address.dropFirst().dropLast()) : address
    }
}
