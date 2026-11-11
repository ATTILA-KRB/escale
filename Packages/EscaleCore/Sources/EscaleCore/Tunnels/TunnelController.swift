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
/// Résultat d'une modification de tunnel actif (`TunnelController.replace`).
public struct TunnelReplaceResult: Equatable, Sendable {
    /// État du tunnel après l'opération.
    public var state: TunnelState
    /// Le nouveau tunnel est ouvert.
    public var applied: Bool
    /// Le nouveau a échoué et l'ancien a été rétabli.
    public var restored: Bool
    /// Message d'erreur (nouveau refusé, ou ancien non rétabli).
    public var error: String?
}

public actor TunnelController {
    public let transport: OpenSSHTransport
    /// Tunnels ouverts par ce contrôleur (spécification telle qu'ouverte : l'arrêt annule exactement celle-ci).
    private var opened: [UUID: TunnelSpec] = [:]
    private var states: [UUID: TunnelState] = [:]
    /// Spécification demandée (avant résolution du port 0 de `-R`), pour comparer et rétablir.
    private var requested: [UUID: TunnelSpec] = [:]
    /// Active la sonde distante des tunnels R.
    public var probesRemote: Bool

    public init(transport: OpenSSHTransport, probesRemote: Bool = true) {
        self.transport = transport; self.probesRemote = probesRemote
    }

    public func state(of id: UUID) -> TunnelState { states[id] ?? .stopped }
    public var allStates: [UUID: TunnelState] { states }
    public var openedTunnels: [TunnelSpec] { Array(opened.values) }

    /// Port attribué par le serveur à un `-R 0` ouvert (nil : tunnel fermé, ou port demandé explicitement).
    public func allocatedPort(of id: UUID) -> Int? {
        guard let r = requested[id], r.kind == .remote, r.bindPort == 0 else { return nil }
        return opened[id]?.bindPort
    }

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
        if spec.bindPort != 0, let other = opened.values.first(where: { $0.id != spec.id && $0.kind == spec.kind && $0.bindPort == spec.bindPort
                                                    && $0.bindAddress == spec.bindAddress }) {
            return set(spec.id, .failed("Le port \(spec.bindPort) est déjà utilisé par le tunnel « \(other.title) »."))
        }
        if spec.kind != .remote, !TunnelPortCheck.isFree(address: spec.bindAddress, port: spec.bindPort) {
            return set(spec.id, .failed("Le port local \(spec.bindPort) est déjà utilisé par un autre programme."))
        }
        let live: TunnelSpec
        // Deux `-R 0` identiques : ssh les fusionne (même port renvoyé) et annuler l'un fermerait l'autre. On refuse le second.
        if spec.kind == .remote, spec.bindPort == 0,
           let other = requested.values.first(where: { $0.id != spec.id && $0.sameForwarding(as: spec) }) {
            return set(spec.id, .failed("Un tunnel identique (« \(other.title) ») est déjà ouvert : le serveur lui a déjà attribué un port. Modifiez la destination."))
        }
        do {
            live = try await transport.openTunnel(spec) // `-R 0` : `live.bindPort` est le port attribué
        } catch {
            return set(spec.id, .failed(Self.message(error)))
        }
        if spec.kind == .remote, probesRemote, await remoteProbe(live) == false {
            try? await transport.removeTunnel(spec)
            return set(spec.id, .failed("Le serveur n'écoute pas sur le port \(live.bindPort) après la demande de redirection."))
        }
        opened[spec.id] = live
        requested[spec.id] = spec
        return set(spec.id, .active)
    }

    /// Modifie un tunnel ouvert : annule l'ancien puis ouvre le nouveau (même identifiant). Si le nouveau échoue,
    /// l'ancien est rétabli et l'erreur est renvoyée : du point de vue de l'utilisateur, soit le nouveau tourne, soit
    /// l'ancien tourne encore. Sans effet si le tunnel n'est pas ouvert ou si la redirection est identique.
    /// Un nouveau invalide est refusé avant de toucher à l'ancien.
    public func replace(with new: TunnelSpec) async -> TunnelReplaceResult {
        guard opened[new.id] != nil, let old = requested[new.id], states[new.id] == .active else {
            return .init(state: state(of: new.id), applied: false, restored: false, error: nil)
        }
        if let first = TunnelValidation.errors(new).first {
            return .init(state: .active, applied: false, restored: false, error: first)
        }
        if old.sameForwarding(as: new) { return .init(state: .active, applied: true, restored: false, error: nil) }
        do {
            try await transport.removeTunnel(old)
        } catch {
            // L'ancien est toujours ouvert (l'annulation a échoué) : on ne tente pas le nouveau.
            return .init(state: .active, applied: false, restored: false, error: "Fermeture de l'ancien tunnel impossible : \(Self.message(error))")
        }
        opened[new.id] = nil; requested[new.id] = nil; states[new.id] = .stopped
        let outcome = await start(new)
        if outcome == .active { return .init(state: .active, applied: true, restored: false, error: nil) }
        let message: String
        if case .failed(let m) = outcome { message = m } else { message = "ouverture impossible" }
        let back = await start(old)
        if back == .active { return .init(state: .active, applied: false, restored: true, error: message) }
        var detail = message
        if case .failed(let m) = back { detail += " ; l'ancien tunnel n'a pas pu être rétabli : \(m)" }
        return .init(state: states[new.id] ?? .stopped, applied: false, restored: false, error: detail)
    }

    /// Ferme le tunnel (`-O cancel`) et vérifie qu'il est fermé. Renvoie `stopped`, ou `failed` si la fermeture a échoué.
    @discardableResult
    public func stop(_ id: UUID) async -> TunnelState {
        guard opened[id] != nil, let spec = requested[id] else { return set(id, .stopped) }
        do {
            try await transport.removeTunnel(spec)
        } catch {
            return set(id, .failed("Fermeture impossible : \(Self.message(error))"))
        }
        opened[id] = nil; requested[id] = nil
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
        opened.removeAll(); requested.removeAll()
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
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:") // « : » : IPv6
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
        let bare = TunnelSpec.unbracketed(address)
        let host = (bare.isEmpty || bare == "*") ? "0.0.0.0" : (bare == "localhost" ? "127.0.0.1" : bare)
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
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
