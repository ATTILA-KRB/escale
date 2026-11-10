import Foundation

/// Flux d'octets bidirectionnel vers un sous-système distant (SFTP).
/// Abstraction volontaire : en test, on branche `/usr/libexec/sftp-server` directement.
public protocol ByteChannel: Sendable {
    /// Lit exactement `count` octets ; lève `ByteChannelError.closed` si le flux se ferme avant.
    func read(exactly count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

public enum ByteChannelError: Error, Equatable, Sendable {
    case closed(reason: String)
}

public enum SSHTransportError: Error, Equatable, Sendable {
    case masterFailed(String)
    case sessionRefused(String)
    case subsystemUnavailable(String)
    case forwardRefused(String)
    case notConnected
}

/// Commande à lancer dans le pty d'un onglet pour obtenir un shell sur la connexion existante.
public struct ShellCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
    }
}

/// Une connexion authentifiée vers un hôte, multiplexée : shells, SFTP et tunnels la partagent.
/// Implémentation V1 : OpenSSH système + ControlMaster. Une implémentation in-process pourra suivre.
public protocol SSHTransport: Sendable {
    var profile: HostProfile { get }
    /// Ouvre la connexion maître (authentification comprise). Idempotent.
    func connect() async throws
    func isAlive() async -> Bool
    func disconnect() async
    /// Commande à exécuter dans un pty local pour un shell interactif sur cette connexion.
    func shellCommand() async throws -> ShellCommand
    /// Ouvre le sous-système SFTP sur cette connexion, sans nouvelle authentification.
    func openSFTPChannel() async throws -> any ByteChannel
    func addTunnel(_ tunnel: TunnelSpec) async throws
    func removeTunnel(_ tunnel: TunnelSpec) async throws
}
