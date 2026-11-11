import Foundation

/// Commande de connexion d'un hôte (`HostProfile.startupCommand`).
///
/// Sémantique (choisie d'après MobaXterm, « Advanced SSH settings › Execute command ») : la commande est TAPÉE dans le shell
/// interactif dès son ouverture, suivie d'Entrée : le shell reste ouvert après elle (équivalent de la case MobaXterm
/// « Do not exit after command ends » cochée), l'environnement de connexion (profil, alias) s'applique, et elle rejoue à
/// chaque nouvelle ouverture du shell, reconnexion comprise. Ce n'est donc PAS un `remoteCommand` ssh (qui remplacerait le
/// shell, sans pty de connexion). PuTTY `RemoteCommand` (qui remplace le shell) est ramené à la même sémantique : la
/// commande s'exécute, mais le shell reste ensuite ouvert.
public enum StartupCommand {
    public static let maxLength = 2000

    /// Commande nettoyée : une seule ligne, sans caractère de contrôle ; `nil` si vide ou inutilisable.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxLength else { return nil }
        if t.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return nil }
        return t
    }

    /// Octets à écrire dans le pty du shell (commande + retour chariot), ou `nil` s'il n'y a rien à envoyer.
    public static func input(for raw: String?) -> Data? {
        normalized(raw).map { Data(($0 + "\r").utf8) }
    }

    /// Message d'erreur français pour l'éditeur d'hôte (`nil` : valide ou vide).
    public static func validationMessage(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.count > maxLength { return "Commande de connexion trop longue (\(maxLength) caractères au plus)." }
        if t.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "La commande de connexion doit tenir sur une seule ligne (séparez les commandes par « ; »)."
        }
        return nil
    }
}
