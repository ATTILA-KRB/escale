import Foundation

/// Un hôte enregistré. Aucun secret ici : uniquement des références (Keychain, fichier de clé).
public struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    public enum Auth: Codable, Hashable, Sendable {
        /// Laisse OpenSSH décider (agent, clés par défaut, ~/.ssh/config).
        case openSSHDefaults
        /// Fichier de clé privée explicite.
        case keyFile(path: String)
        /// Mot de passe lu dans le Keychain via askpass.
        case keychainPassword(account: String)
    }

    public var id: UUID
    public var name: String
    /// Nom d'hôte, IP, ou alias de ~/.ssh/config.
    public var host: String
    public var port: Int?
    public var user: String?
    public var auth: Auth
    /// Bastions traversés dans l'ordre (ProxyJump), au format `user@host:port`.
    public var jumpHosts: [String]
    public var tags: [String]
    /// Dossier de la bibliothèque qui contient cet hôte (`nil` = racine).
    public var folderID: UUID?
    /// Tunnels enregistrés pour cet hôte (M3). Absent des bibliothèques antérieures : liste vide.
    public var tunnels: [TunnelSpec]
    /// Redirection X11 via XQuartz (M5). Absent des bibliothèques antérieures : désactivée.
    public var x11Forwarding: Bool
    /// Commande tapée dans le shell juste après son ouverture (import MobaXterm « Execute command », PuTTY `RemoteCommand`).
    /// Voir `StartupCommand`. Absente des bibliothèques antérieures : `nil`.
    public var startupCommand: String?
    /// Protocole (V1.2/V2). Absent des bibliothèques antérieures : SSH.
    public var connectionProtocol: ConnectionProtocol
    /// Réglages propres au protocole (`nil` : défauts). Seul celui du protocole courant sert.
    public var serial: SerialSettings?
    public var telnet: TelnetSettings?
    public var vnc: VNCSettings?
    public var rdp: RDPSettings?
    /// Accès des agents IA (serveur MCP d'Escale). Absent des bibliothèques antérieures : `none` (hôte invisible).
    public var agentAccess: AgentAccess

    public init(
        id: UUID = UUID(), name: String, host: String, port: Int? = nil, user: String? = nil,
        auth: Auth = .openSSHDefaults, jumpHosts: [String] = [], tags: [String] = [], folderID: UUID? = nil,
        tunnels: [TunnelSpec] = [], x11Forwarding: Bool = false, startupCommand: String? = nil,
        connectionProtocol: ConnectionProtocol = .ssh, serial: SerialSettings? = nil, telnet: TelnetSettings? = nil,
        vnc: VNCSettings? = nil, rdp: RDPSettings? = nil, agentAccess: AgentAccess = .none
    ) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.user = user
        self.auth = auth; self.jumpHosts = jumpHosts; self.tags = tags; self.folderID = folderID
        self.tunnels = tunnels; self.x11Forwarding = x11Forwarding; self.startupCommand = startupCommand
        self.connectionProtocol = connectionProtocol; self.serial = serial; self.telnet = telnet; self.vnc = vnc; self.rdp = rdp
        self.agentAccess = agentAccess
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, user, auth, jumpHosts, tags, folderID, tunnels, x11Forwarding, startupCommand
        case connectionProtocol, serial, telnet, vnc, rdp, agentAccess
    }

    /// Décodage tolérant : les champs ajoutés après la première version ont une valeur par défaut,
    /// une bibliothèque existante se relit donc sans migration.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .openSSHDefaults
        jumpHosts = try c.decodeIfPresent([String].self, forKey: .jumpHosts) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        tunnels = try c.decodeIfPresent([TunnelSpec].self, forKey: .tunnels) ?? []
        x11Forwarding = try c.decodeIfPresent(Bool.self, forKey: .x11Forwarding) ?? false
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        connectionProtocol = try c.decodeIfPresent(ConnectionProtocol.self, forKey: .connectionProtocol) ?? .ssh
        serial = try c.decodeIfPresent(SerialSettings.self, forKey: .serial)
        telnet = try c.decodeIfPresent(TelnetSettings.self, forKey: .telnet)
        vnc = try c.decodeIfPresent(VNCSettings.self, forKey: .vnc)
        rdp = try c.decodeIfPresent(RDPSettings.self, forKey: .rdp)
        // Valeur inconnue (version plus récente) : repli sur `none`, jamais sur un accès plus large.
        agentAccess = (try? c.decodeIfPresent(AgentAccess.self, forKey: .agentAccess)) ?? AgentAccess.none
    }

    /// Cible passée à ssh (`user@host` ou `host`).
    public var target: String { user.map { "\($0)@\(host)" } ?? host }
}
