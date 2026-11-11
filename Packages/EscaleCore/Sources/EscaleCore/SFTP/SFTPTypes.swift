import Foundation

/// Chemin distant exprimé en octets. `String` (UTF-8) et `Data` (octets bruts, pour les noms non UTF-8) l'adoptent.
public protocol SFTPPathRepresentable: Sendable {
    var sftpBytes: Data { get }
}
extension String: SFTPPathRepresentable { public var sftpBytes: Data { Data(utf8) } }
extension Data: SFTPPathRepresentable { public var sftpBytes: Data { self } }

/// Type d'un élément distant, déduit des bits de type des permissions.
public enum SFTPFileType: Sendable, Equatable {
    case regular, directory, symlink
    /// Socket, périphérique, FIFO…
    case other
    /// Le serveur n'a pas fourni de permissions.
    case unknown
}

/// Attributs SFTP v3 (tous optionnels : le serveur n'en renseigne qu'une partie).
public struct SFTPAttributes: Sendable, Equatable, Hashable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    /// Mode complet (bits de type inclus, ex. 0o100644).
    public var permissions: UInt32?
    public var accessTime: Date?
    public var modificationTime: Date?

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil,
                accessTime: Date? = nil, modificationTime: Date? = nil) {
        self.size = size; self.uid = uid; self.gid = gid; self.permissions = permissions
        self.accessTime = accessTime; self.modificationTime = modificationTime
    }

    public var type: SFTPFileType {
        guard let p = permissions else { return .unknown }
        switch p & 0o170000 {
        case 0o100000: return .regular
        case 0o040000: return .directory
        case 0o120000: return .symlink
        default: return .other
        }
    }
    /// Bits de permission seuls (rwx, setuid…), sans le type.
    public var permissionBits: UInt32? { permissions.map { $0 & 0o7777 } }
}

/// Entrée de listage. Choix pour les noms non UTF-8 : `nameBytes` conserve les octets exacts (réversible,
/// utilisable comme chemin via `Data`), `name` est une version lisible où les octets invalides deviennent U+FFFD,
/// et `nameIsValidUTF8` le signale. Aucune normalisation Unicode (NFC/NFD) n'est appliquée.
public struct SFTPDirectoryEntry: Sendable, Equatable, Hashable {
    public let name: String
    public let nameBytes: Data
    public let attributes: SFTPAttributes

    public init(nameBytes: Data, attributes: SFTPAttributes) {
        self.nameBytes = nameBytes
        self.name = String(decoding: nameBytes, as: UTF8.self)
        self.attributes = attributes
    }
    public var type: SFTPFileType { attributes.type }
    public var nameIsValidUTF8: Bool { String(data: nameBytes, encoding: .utf8) != nil }
}

/// Progression d'un transfert. `bytesTransferred` inclut l'offset de reprise ; `totalBytes` est la taille du fichier complet si connue.
public struct SFTPTransferProgress: Sendable, Equatable {
    public var bytesTransferred: UInt64
    public var totalBytes: UInt64?
}

/// Réglages du client.
public struct SFTPClientConfiguration: Sendable, Equatable {
    /// Délai maximal pour recevoir VERSION après INIT.
    public var negotiationTimeout: Duration = .seconds(10)
    /// Taille d'une requête READ/WRITE (réduite si le serveur annonce une limite plus basse).
    public var chunkSize: Int = 32 * 1024
    /// Nombre maximal de requêtes de transfert en vol.
    public var window: Int = 32
    /// Délai sans AUCUNE réponse du serveur au-delà duquel les requêtes en attente échouent en `requestTimeout`.
    /// Le délai court depuis le dernier signe de vie (envoi ou réponse reçue), pas depuis l'envoi de chaque requête :
    /// un lien lent mais vivant ne déclenche rien. `nil` = pas de délai.
    public var requestTimeout: Duration? = .seconds(60)
    /// Nombre de délais successifs, sans réponse entre-temps, après lesquels le canal est déclaré mort.
    public var maxConsecutiveTimeouts: Int = 3
    /// Ajuste la fenêtre de requêtes en vol pendant un transfert (montée tant que le débit croît, repli sinon).
    /// `window` sert alors de valeur initiale. `false` : fenêtre fixe de `window` requêtes.
    public var adaptiveWindow: Bool = true
    /// Bornes de la fenêtre adaptative (la valeur initiale `window` est ramenée dans ces bornes).
    public var minWindow: Int = 4
    public var maxWindow: Int = 256
    public init() {}
}

/// Instantané de progression d'un transfert, destiné à l'interface.
public struct SFTPTransferSnapshot: Sendable, Equatable {
    /// Octets déjà en place, offset de reprise inclus.
    public var bytesTransferred: UInt64
    /// Taille du fichier complet si connue.
    public var totalBytes: UInt64?
    /// Débit lissé (octets/s) sur les dernières secondes ; 0 tant qu'il n'est pas mesurable.
    public var bytesPerSecond: Double
    /// Fenêtre de requêtes en vol utilisée à cet instant.
    public var window: Int
    /// Durée écoulée depuis le début du transfert (vérification de reprise comprise).
    public var elapsed: Duration
    /// Fraction 0…1 si la taille est connue.
    public var fraction: Double? {
        guard let t = totalBytes else { return nil }
        return t == 0 ? 1 : min(1, Double(bytesTransferred) / Double(t))
    }
    /// Temps restant estimé, si le débit et la taille sont connus.
    public var estimatedRemaining: Duration? {
        guard let t = totalBytes, bytesPerSecond > 1, t >= bytesTransferred else { return nil }
        return .seconds(Double(t - bytesTransferred) / bytesPerSecond)
    }
}

/// Résultat d'un transfert avec reprise vérifiée.
public struct SFTPTransferOutcome: Sendable, Equatable {
    /// Taille finale du fichier transféré.
    public var totalBytes: UInt64
    /// Offset réellement repris (0 = transfert complet depuis le début).
    public var resumedFrom: UInt64
    /// Si une reprise était possible (données partielles présentes) mais refusée : la raison. `nil` sinon.
    public var restartReason: String?
}

/// Niveau de vérification du préfixe déjà transféré avant de reprendre.
public enum SFTPResumeVerification: Sendable, Equatable {
    /// Compare le SHA-256 des `head` premiers octets et des `tail` derniers octets du préfixe (local contre distant).
    /// Rapide ; ne détecte pas une modification au milieu du préfixe.
    case sample(head: Int, tail: Int)
    /// Compare le SHA-256 de tout le préfixe (relit les deux côtés ; coûteux sur un gros préfixe).
    case full
    /// Valeur par défaut : 64 Kio de tête et 1 Mio de queue.
    public static let `default` = SFTPResumeVerification.sample(head: 64 * 1024, tail: 1024 * 1024)
}
