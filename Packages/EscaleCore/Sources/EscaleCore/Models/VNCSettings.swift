import Foundation

/// Encodage préféré pour les rectangles d'écran (le client sait décoder Raw, CopyRect, RRE, Hextile et ZRLE).
public enum VNCEncodingPreference: String, Codable, CaseIterable, Hashable, Sendable {
    /// ZRLE puis Hextile, RRE, CopyRect, Raw (le plus économe en bande passante).
    case auto
    /// ZRLE d'abord (compression zlib).
    case zrle
    /// Hextile d'abord (sans compression, peu de CPU).
    case hextile
    /// Raw seulement (réseau local rapide, serveurs capricieux).
    case raw

    public var displayName: String {
        switch self {
        case .auto: "Automatique"
        case .zrle: "ZRLE"
        case .hextile: "Hextile"
        case .raw: "Brut (Raw)"
        }
    }
}

/// Mise à l'échelle de l'affichage distant dans la fenêtre.
public enum VNCScaling: String, Codable, CaseIterable, Hashable, Sendable {
    /// Ajuster à la fenêtre (proportions conservées).
    case fit
    /// 100 % (un pixel distant = un point), défilement si la fenêtre est plus petite.
    case actual

    public var displayName: String {
        switch self {
        case .fit: "Ajuster à la fenêtre"
        case .actual: "100 %"
        }
    }
}

/// Réglages VNC (protocole `.vnc`) : hôte et port sont ceux de `HostProfile`.
/// Décodage tolérant : toute clé absente prend sa valeur par défaut. Aucun mot de passe ici (invariant 7) :
/// il vit dans le Keychain, sous un compte dérivé de l'identifiant de l'hôte.
public struct VNCSettings: Codable, Hashable, Sendable {
    /// Hôte SSH (identifiant dans la bibliothèque) dont le maître porte un tunnel local vers le serveur VNC.
    /// `HostProfile.host`/`port` sont alors l'adresse du serveur VUE DEPUIS cet hôte SSH.
    public var viaSSHHostID: UUID?
    /// Lecture seule : aucun clavier ni souris n'est envoyé.
    public var viewOnly: Bool
    /// Session partagée (ClientInit « shared ») : ne pas déconnecter les autres clients.
    public var shared: Bool
    public var encoding: VNCEncodingPreference
    public var scaling: VNCScaling

    public init(viaSSHHostID: UUID? = nil, viewOnly: Bool = false, shared: Bool = true,
                encoding: VNCEncodingPreference = .auto, scaling: VNCScaling = .fit) {
        self.viaSSHHostID = viaSSHHostID; self.viewOnly = viewOnly; self.shared = shared
        self.encoding = encoding; self.scaling = scaling
    }

    private enum CodingKeys: String, CodingKey { case viaSSHHostID, viewOnly, shared, encoding, scaling }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        viaSSHHostID = try c.decodeIfPresent(UUID.self, forKey: .viaSSHHostID)
        viewOnly = try c.decodeIfPresent(Bool.self, forKey: .viewOnly) ?? false
        shared = try c.decodeIfPresent(Bool.self, forKey: .shared) ?? true
        // Valeur inconnue (version future) : retombe sur le défaut plutôt que de rendre l'hôte illisible.
        encoding = (try? c.decodeIfPresent(VNCEncodingPreference.self, forKey: .encoding)) ?? .auto
        scaling = (try? c.decodeIfPresent(VNCScaling.self, forKey: .scaling)) ?? .fit
    }

    /// Messages d'erreur de validation (vide : valide). Le tunnel ne peut pas passer par l'hôte lui-même.
    public static func validationErrors(_ s: VNCSettings, hostID: UUID? = nil) -> [String] {
        var e: [String] = []
        if let via = s.viaSSHHostID, let hostID, via == hostID {
            e.append("Le tunnel SSH ne peut pas passer par l'hôte VNC lui-même.")
        }
        return e
    }

    /// Compte Keychain du mot de passe VNC : le même que celui du mot de passe SSH (`AuthKeychain.passwordAccount`), un hôte
    /// n.ayant qu.un protocole ; la suppression de l.hôte l.efface donc avec les autres secrets.
    public static func passwordAccount(for hostID: UUID) -> String { "host-\(hostID.uuidString)" }
}
