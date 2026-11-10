import Foundation

/// Branchement askpass d'`OpenSSHTransport` : sans cette configuration, ssh reste en `BatchMode` (comportement historique).
public struct AskpassConfiguration: Sendable {
    /// Exécutable désigné par `SSH_ASKPASS` : `escale-askpass`, ou l'app elle-même (qui appelle `AskpassClient.runIfRequested()`).
    public var executablePath: String
    public var responder: any AskpassResponder
    public var limits: AskpassServer.Limits
    /// Dossier parent du dossier 0700 du socket askpass (défaut : `NSTemporaryDirectory()`).
    public var socketDirectory: String?

    public init(
        executablePath: String, responder: any AskpassResponder,
        limits: AskpassServer.Limits = AskpassServer.Limits(), socketDirectory: String? = nil
    ) {
        self.executablePath = executablePath; self.responder = responder
        self.limits = limits; self.socketDirectory = socketDirectory
    }
}

/// Échecs d'authentification distinguables (levés par `connect()` quand `askpass` est configuré).
/// Les messages viennent du journal de ssh : ils ne contiennent aucun secret.
public enum SSHAuthenticationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Mot de passe, phrase de passe ou code refusé par le serveur.
    case wrongSecret(String)
    /// L'utilisateur a annulé une invite.
    case cancelled
    /// La clé d'hôte a changé : connexion refusée, jamais proposée à l'utilisateur.
    case hostKeyChanged(String)
    /// L'utilisateur a refusé la clé d'une hôte inconnue.
    case hostKeyRejected
    /// Aucune réponse à une invite dans le délai imparti.
    case timedOut

    public var description: String {
        switch self {
        case .wrongSecret(let m): "secret refusé : \(m)"
        case .cancelled: "authentification annulée"
        case .hostKeyChanged(let m): "clé d'hôte modifiée : \(m)"
        case .hostKeyRejected: "clé d'hôte refusée"
        case .timedOut: "délai dépassé pendant l'authentification"
        }
    }
}
