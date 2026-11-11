import Foundation

/// Nature du système de fichiers distant utilisé par le navigateur.
public enum RemoteFileSystemKind: Sendable, Equatable {
    /// Sous-système SFTP du serveur.
    case sftp
    /// Repli : commandes `exec` sur le maître (`ls`, `stat`, `cat`, `dd`…), quand le serveur refuse le SFTP.
    case shell
}

/// Opérations de fichiers distants, indépendantes du protocole. Implémentée par `SFTPClient` (SFTP v3) et par
/// `ShellFileSystem` (sessions exec). Les chemins sont des octets (`Data`) : un nom non UTF-8 reste adressable en SFTP.
public protocol RemoteFileSystem: Sendable {
    var kind: RemoteFileSystemKind { get }

    /// Chemin canonique absolu (`.` = dossier de connexion).
    func canonicalPath(_ path: Data) async throws -> String
    /// Attributs ; `followLinks` suit les liens symboliques (stat) ou non (lstat).
    func attributes(of path: Data, followLinks: Bool) async throws -> SFTPAttributes
    /// Contenu d'un dossier, sans `.` ni `..`.
    func listEntries(in path: Data) async throws -> [SFTPDirectoryEntry]
    func makeDirectory(_ path: Data) async throws
    func removeDirectory(_ path: Data) async throws
    /// Supprime un fichier (ou lien) ; échoue sur un dossier.
    func removeFile(_ path: Data) async throws
    /// Renomme ou déplace dans le même système de fichiers. Une destination existante est remplacée (fichier).
    func renameItem(_ from: Data, to: Data) async throws
    /// Lit jusqu'à `length` octets à `offset` (moins en fin de fichier ; vide au-delà).
    func readBlock(_ path: Data, offset: UInt64, length: Int) async throws -> Data
    /// Écrit `data` à `offset` ; le fichier est créé si besoin et tronqué d'abord si `truncate` (avec `offset == 0`).
    func writeBlock(_ path: Data, offset: UInt64, data: Data, truncate: Bool) async throws
    /// Copie un fichier ou un dossier (récursivement) vers un chemin qui n'existe pas encore.
    func copyItem(from: Data, to: Data) async throws

    /// Téléchargement suivi ; `resume` : reprise vérifiée à partir du fichier local partiel.
    nonisolated func startDownload(remotePath: Data, to localURL: URL, resume: Bool,
                                   verification: SFTPResumeVerification) -> SFTPTransferTask
    /// Envoi suivi ; `resume` : reprise vérifiée à partir du fichier distant partiel.
    nonisolated func startUpload(localURL: URL, to remotePath: Data, resume: Bool,
                                 verification: SFTPResumeVerification) -> SFTPTransferTask

    /// Supprime l'envoi partiel laissé par un transfert annulé (le fichier lui-même en SFTP, `<fichier>.part` en mode shell).
    func discardPartialUpload(at path: Data) async

    func close() async
}

public extension RemoteFileSystem {
    func attributes(of path: Data) async throws -> SFTPAttributes { try await attributes(of: path, followLinks: true) }

    /// Télécharge tout un fichier (sans reprise) et attend la fin.
    @discardableResult
    func download(_ remotePath: Data, to localURL: URL) async throws -> SFTPTransferOutcome {
        try await startDownload(remotePath: remotePath, to: localURL, resume: false, verification: .default).outcome
    }

    /// Envoie tout un fichier (sans reprise) et attend la fin.
    @discardableResult
    func upload(_ localURL: URL, to remotePath: Data) async throws -> SFTPTransferOutcome {
        try await startUpload(localURL: localURL, to: remotePath, resume: false, verification: .default).outcome
    }

    /// Supprime un dossier et son contenu.
    func removeTree(_ path: Data) async throws {
        for e in try await listEntries(in: path) {
            let child = path.remoteJoined(e.nameBytes)
            if e.type == .directory { try await removeTree(child) } else { try await removeFile(child) }
        }
        try await removeDirectory(path)
    }
}

extension Data {
    /// `self` + « / » + `name` (sans doubler la barre).
    func remoteJoined(_ name: Data) -> Data {
        var d = self
        if d.last != UInt8(ascii: "/") { d.append(UInt8(ascii: "/")) }
        d.append(name)
        return d
    }
}
