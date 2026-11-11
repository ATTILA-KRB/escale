import Foundation

/// Code de statut SSH_FXP_STATUS (SFTP v3). `unknown` conserve la valeur brute d'un code non standard.
public enum SFTPStatusCode: Sendable, Equatable, Hashable {
    case ok, eof, noSuchFile, permissionDenied, failure, badMessage
    case noConnection, connectionLost, opUnsupported
    case unknown(UInt32)

    public init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .ok
        case 1: self = .eof
        case 2: self = .noSuchFile
        case 3: self = .permissionDenied
        case 4: self = .failure
        case 5: self = .badMessage
        case 6: self = .noConnection
        case 7: self = .connectionLost
        case 8: self = .opUnsupported
        default: self = .unknown(rawValue)
        }
    }
}

/// Erreurs du client SFTP : statut renvoyé par le serveur, protocole, canal, E/S locales.
public enum SFTPError: Error, Equatable, Sendable {
    /// Le serveur a répondu par un statut d'échec (code + message du serveur, éventuellement vide).
    case status(SFTPStatusCode, message: String)
    /// Réponse mal formée ou inattendue.
    case protocolViolation(String)
    /// Le canal s'est fermé (serveur mort, connexion coupée, `close()` local) ; toutes les requêtes en vol échouent avec ceci.
    case channelClosed(String)
    /// Le serveur n'a pas répondu à INIT dans le délai imparti.
    case negotiationTimeout
    /// Version de protocole non supportée (seule la v3 l'est).
    case unsupportedVersion(UInt32)
    /// Erreur sur le fichier local (message avec errno).
    case localIO(String)
    /// Offset de reprise incohérent avec l'état du fichier local ou distant.
    case invalidResumeOffset(String)
    /// Transfert annulé (Task cancellation). `partialLocalFile` : fichier local partiel laissé en place
    /// (téléchargement uniquement ; en envoi, le fichier distant partiel reste sur le serveur).
    case cancelled(partialLocalFile: URL?, bytesTransferred: UInt64)
    /// Aucune réponse du serveur depuis `seconds` secondes alors qu'une requête était en attente. La requête est libérée ;
    /// sa réponse tardive éventuelle est ignorée (le canal reste cohérent). Après plusieurs délais d'affilée sans la
    /// moindre réponse, le canal est déclaré mort (`channelClosed`).
    case requestTimeout(seconds: Double)
}
