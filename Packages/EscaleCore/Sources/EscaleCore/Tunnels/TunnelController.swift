import Foundation

/// État d'un tunnel pour l'interface.
public enum TunnelState: Equatable, Sendable {
    case stopped
    case opening
    case active
    case failed(String)

    public var isActive: Bool { self == .active }
}

/// Ouvre et ferme des tunnels sur le maître d'une connexion (`ssh -O forward` / `-O cancel`, via le transport).
///
/// Invariant 4 : `-O forward` renvoie 0 même en cas de refus. Vérification d'un tunnel ouvert :
/// - L et D : le transport sonde le port local (et le journal du maître pour un canal rejeté) ; en amont, ce contrôleur
///   teste par `bind` que le port est libre, pour un message clair plutôt qu'un « Address already in use » de ssh ;
/// - R : le maître attend la réponse du serveur à `tcpip-forward` (refus = message d'erreur de `-O forward`, relevé par le
///   transport), puis une sonde distante confirme que le port écoute côté serveur (session exec `bash /dev/tcp`).
///   Choix de la sonde exec plutôt que du seul journal : le journal du maître ne contient rien en cas de succès, et une
///   session courte ne coûte qu'une place du plafond de 10 sessions le temps de l'ouverture. Si la sonde ne peut pas
///   répondre (plafond atteint, pas de bash côté serveur), on se fie à la réponse du serveur.
public actor TunnelController {
    public let transport: OpenSSHTransport
    /// Tunnels ouverts par ce contrôleur (spécification telle qu'ouverte : l'arrêt annule exactement celle-ci).
    private var opened: [UUID: TunnelSpec] = [:]
    private var states: [UUID: TunnelState] = [:]
    /// Active la sonde distante des tunnels R.
    public var probesRemote: Bool

    public init(transport: OpenSSHTransport, probesRemote: Bool = true) {
        self.transport = transport; self.probesRemote = probesRemote
    }

    public func state(of id: UUID) -> TunnelState { states[id] ?? .stopped }
    public var allStates: [UUID: TunnelState] { states }
    public var openedTunnels: [TunnelSpec] { Array(opened.values) }

    // MARK: Ouverture

    /// Ouvre le tunnel et renvoie son état final (`active` ou `failed`). Idempotent si déjà actif.
    @discardableResult
    public func start(_ spec: TunnelSpec) async -> TunnelState {
        switch states[spec.id] {
        case .active?, .opening?: return states[spec.id] ?? .opening
        default: break
        }
        let errors = TunnelValidation.errors(spec)
        if let first = errors.first { return set(spec.id, .failed(first)) }
        states[spec.id] = .opening
        // Même port d'écoute déjà pris par un autre tunnel ouvert de ce maître.
        if let other = opened.values.first(where: { $0.id != spec.id && $0.kind == spec.kind && $0.bindPort == spec.bindPort
                                                    && $0.bindAddress == spec.bindAddress }) {
            return set(spec.id, .failed("Le port \(spec.bindPort) est déjà utilisé par le tunnel « \(other.title) »."))
        }
        if spec.kind != .remote, !TunnelPortCheck.isFree(address: spec.bindAddress, port: spec.bindPort) {
            return set(spec.id, .failed("Le port local \(spec.bindPort) est déjà utilisé par un autre programme."))
        }
        do {
            try await transport.addTunnel(spec)
        } catch {
            return set(spec.id, .failed(Self.message(error)))
        }
        if spec.kind == .remote, probesRemote, await remoteProbe(spec) == false {
            try? await transport.removeTunnel(spec)
            return set(spec.id, .failed("Le serveur n'écoute pas sur le port \(spec.bindPort) après la demande de redirection."))
        }
        opened[spec.id] = spec
        return set(spec.id, .active)
    }

    /// Ferme le tunnel (`-O cancel`) et vérifie qu'il est fermé. Renvoie `stopped`, ou `failed` si la fermeture a échoué.
    @discardableResult
    public func stop(_ id: UUID) async -> TunnelState {
        guard let spec = opened[id] else { return set(id, .stopped) }
        do {
            try await transport.removeTunnel(spec)
        } catch {
            return set(id, .failed("Fermeture impossible : \(Self.message(error))"))
        }
        opened[id] = nil
        return set(id, .stopped)
    }

    public func stopAll() async {
        for id in Array(opened.keys) { await stop(id) }
    }

    /// Rouvre une liste de tunnels (après reconnexion), un par un ; renvoie les états obtenus.
    @discardableResult
    public func reopen(_ specs: [TunnelSpec]) async -> [UUID: TunnelState] {
        var out: [UUID: TunnelState] = [:]
        for s in specs { out[s.id] = await start(s) }
        return out
    }

    /// Le maître est mort ou fermé : plus rien n'est ouvert, sans appel ssh (le socket n'existe plus).
    public func connectionLost() {
        opened.removeAll()
        for id in Array(states.keys) { states[id] = .stopped }
    }

    /// Oublie l'état d'un tunnel supprimé de la bibliothèque.
    public func forget(_ id: UUID) { states[id] = nil }

    // MARK: Interne

    @discardableResult
    private func set(_ id: UUID, _ s: TunnelState) -> TunnelState { states[id] = s; return s }

    static func message(_ error: Error) -> String {
        switch error {
        case SSHTransportError.forwardRefused(let m):
            let lines = OpenSSHJournal.meaningfulLines(m)
            return OpenSSHJournal.lastError(lines.joined(separator: "\n")) ?? m
        case SSHTransportError.notConnected: return "Connexion non établie."
        case SSHTransportError.masterFailed(let m), SSHTransportError.sessionRefused(let m),
             SSHTransportError.subsystemUnavailable(let m): return m
        default: return "\(error)"
        }
    }

    /// true : le serveur écoute ; false : refus certain ; nil : sonde impossible (on se fie à ssh).
    private func remoteProbe(_ spec: TunnelSpec) async -> Bool? {
        let host = TunnelValidation.displayBind(spec.bindAddress)
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard host.unicodeScalars.allSatisfy({ safe.contains($0) }) else { return nil }
        let script = "if command -v bash >/dev/null 2>&1; then if bash -c 'exec 3<>/dev/tcp/\(host)/\(spec.bindPort)' 2>/dev/null; "
            + "then echo ESCALE_PROBE_OPEN; else echo ESCALE_PROBE_CLOSED; fi; else echo ESCALE_PROBE_UNKNOWN; fi"
        let cmd: ShellCommand
        do { cmd = try await transport.shellCommand(remoteCommand: script) } catch { return nil }
        let r = await OpenSSHProcessRunner.run(
            executable: cmd.executable, arguments: cmd.arguments, environment: cmd.environment, timeout: 8)
        await transport.shellSessionDidEnd()
        if r.stdout.contains("ESCALE_PROBE_OPEN") { return true }
        if r.stdout.contains("ESCALE_PROBE_CLOSED") { return false }
        return nil
    }
}

/// Test de disponibilité d'un port local : un `bind` réel, avec SO_REUSEADDR comme ssh.
public enum TunnelPortCheck {
    public static func isFree(address: String, port: Int) -> Bool {
        let host = (address.isEmpty || address == "*") ? "0.0.0.0" : (address == "localhost" ? "127.0.0.1" : address)
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return true } // adresse inconnue : ssh tranchera
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        // Seul EADDRINUSE prouve que le port est pris (EACCES, etc. : ssh donnera son propre message).
        return bind(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 || errno != EADDRINUSE
    }
}
