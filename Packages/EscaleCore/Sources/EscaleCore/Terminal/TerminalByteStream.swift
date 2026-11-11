import Foundation

/// Source d'octets branchée sur un panneau de terminal : pty d'un processus (shell local, ssh), port série,
/// connexion Telnet. Contrat figé de la vague V1.2 : ajouter des membres, ne jamais changer une signature.
public protocol TerminalByteStream: AnyObject, Sendable {
    /// Octets reçus, à afficher. Se termine à la fin de la session. Un seul consommateur.
    var output: AsyncStream<Data> { get }
    /// Saisie de l'utilisateur (déjà encodée par le moteur de terminal).
    func write(_ data: Data)
    /// Taille de l'écran (Telnet NAWS ; sans effet sur un port série).
    func resize(columns: Int, rows: Int)
    /// Fermeture immédiate (fermeture du panneau, arrêt de l'app). Idempotent.
    func kill()
    /// Attend la fin de la session ; quand elle rend la main, `output` est terminé.
    func waitForExit() async -> PTYExitStatus
}

extension PTYProcess: TerminalByteStream {}
