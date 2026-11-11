import Foundation

/// Erreurs de construction d'une ligne de commande ssh (entrées refusées avant tout lancement).
public enum OpenSSHCommandBuilderError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidHost(String)
    case invalidUser(String)
    case invalidPort(Int)
    case invalidJumpHost(String)
    case invalidKeyPath(String)
    case invalidOption(String)
    case invalidControlPath(String)
    case invalidTunnel(String)

    public var description: String {
        switch self {
        case .invalidHost(let v): "hôte invalide : \(v.debugDescription)"
        case .invalidUser(let v): "utilisateur invalide : \(v.debugDescription)"
        case .invalidPort(let v): "port invalide : \(v)"
        case .invalidJumpHost(let v): "bastion invalide : \(v.debugDescription)"
        case .invalidKeyPath(let v): "chemin de clé invalide : \(v.debugDescription)"
        case .invalidOption(let v): "option ssh invalide : \(v.debugDescription)"
        case .invalidControlPath(let v): "chemin de socket de contrôle invalide : \(v.debugDescription)"
        case .invalidTunnel(let v): "tunnel invalide : \(v)"
        }
    }
}

/// Réglages de la ligne de commande ssh, indépendants de l'hôte visé.
public struct OpenSSHOptions: Sendable, Equatable {
    public enum StrictHostKeyChecking: String, Sendable, Equatable {
        case yes, no, ask
        case acceptNew = "accept-new"
    }

    public var sshPath: String
    /// `-F` : fichier de configuration (ex. `/dev/null` en test pour ignorer `~/.ssh/config`).
    public var configFile: String?
    /// `-o UserKnownHostsFile=` (injectable pour ne jamais toucher `~/.ssh/known_hosts` en test).
    public var userKnownHostsFile: String?
    public var strictHostKeyChecking: StrictHostKeyChecking?
    /// `BatchMode=yes` : jamais d'invite interactive.
    public var batchMode: Bool
    public var connectTimeout: Int
    public var serverAliveInterval: Int
    public var serverAliveCountMax: Int
    /// Options supplémentaires au format `Cle=Valeur`, passées par `-o`, placées après les options dédiées
    /// (ssh retient la première valeur rencontrée : elles ne peuvent donc pas écraser les options dédiées).
    public var extraOptions: [String]
    /// Variables ajoutées à l'environnement des processus ssh (prévu pour `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE`).
    public var environment: [String: String]

    public init(
        sshPath: String = "/usr/bin/ssh", configFile: String? = nil, userKnownHostsFile: String? = nil,
        strictHostKeyChecking: StrictHostKeyChecking? = nil, batchMode: Bool = true,
        connectTimeout: Int = 10, serverAliveInterval: Int = 5, serverAliveCountMax: Int = 2,
        extraOptions: [String] = [], environment: [String: String] = [:]
    ) {
        self.sshPath = sshPath; self.configFile = configFile; self.userKnownHostsFile = userKnownHostsFile
        self.strictHostKeyChecking = strictHostKeyChecking; self.batchMode = batchMode
        self.connectTimeout = connectTimeout; self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax; self.extraOptions = extraOptions
        self.environment = environment
    }
}

/// Construit les tableaux d'arguments de ssh. Pur et sans effet de bord : aucune interpolation shell,
/// jamais de chaîne de commande, uniquement des tableaux.
public struct OpenSSHCommandBuilder: Sendable, Equatable {
    public enum ControlOperation: Sendable, Equatable {
        case check, exit
        case forward(TunnelSpec)
        case cancel(TunnelSpec)
    }

    public let profile: HostProfile
    public let controlPath: String
    public let options: OpenSSHOptions

    /// Valide le profil et les options ; lève une erreur plutôt que de produire une ligne dangereuse.
    public init(profile: HostProfile, controlPath: String, options: OpenSSHOptions = OpenSSHOptions()) throws {
        self.profile = profile; self.controlPath = controlPath; self.options = options
        try Self.validateHostLike(profile.host, error: OpenSSHCommandBuilderError.invalidHost)
        if let user = profile.user {
            try Self.validateHostLike(user, error: OpenSSHCommandBuilderError.invalidUser)
            if user.contains("@") { throw OpenSSHCommandBuilderError.invalidUser(user) }
        }
        if let port = profile.port, !(1...65535).contains(port) { throw OpenSSHCommandBuilderError.invalidPort(port) }
        for jump in profile.jumpHosts {
            try Self.validateHostLike(jump, error: OpenSSHCommandBuilderError.invalidJumpHost)
            if jump.contains(",") { throw OpenSSHCommandBuilderError.invalidJumpHost(jump) }
        }
        if case .keyFile(let path) = profile.auth, path.isEmpty || Self.hasControlOrNul(path) {
            throw OpenSSHCommandBuilderError.invalidKeyPath(path)
        }
        if controlPath.isEmpty || controlPath.hasPrefix("-") || Self.hasControlOrNul(controlPath) {
            throw OpenSSHCommandBuilderError.invalidControlPath(controlPath)
        }
        for opt in options.extraOptions where opt.isEmpty || !opt.contains("=") || Self.hasControlOrNul(opt) {
            throw OpenSSHCommandBuilderError.invalidOption(opt)
        }
    }

    // MARK: - Lignes de commande

    /// Maître : `ssh -M -S <sock> -N -o ControlPersist=no …`. Reste au premier plan tant que la connexion vit.
    public func masterArguments() -> [String] {
        var a = ["-M", "-S", controlPath, "-N", "-o", "ControlPersist=no"]
        a += ["-o", "BatchMode=\(options.batchMode ? "yes" : "no")"]
        a += ["-o", "ConnectTimeout=\(options.connectTimeout)"]
        a += ["-o", "ServerAliveInterval=\(options.serverAliveInterval)", "-o", "ServerAliveCountMax=\(options.serverAliveCountMax)"]
        if let f = options.configFile { a += ["-F", f] }
        a += targetOptions()
        if !profile.jumpHosts.isEmpty { a += ["-J", profile.jumpHosts.joined(separator: ",")] }
        if let k = options.userKnownHostsFile { a += ["-o", "UserKnownHostsFile=\(k)"] }
        if let s = options.strictHostKeyChecking { a += ["-o", "StrictHostKeyChecking=\(s.rawValue)"] }
        for o in options.extraOptions { a += ["-o", o] }
        return a + ["--", profile.target]
    }

    /// Opération de contrôle sur le maître (`-O check|exit|forward|cancel`).
    public func controlArguments(_ operation: ControlOperation) throws -> [String] {
        var a = secondaryPrefix() + targetOptions()
        switch operation {
        case .check: a += ["-O", "check"]
        case .exit: a += ["-O", "exit"]
        case .forward(let t): try Self.validate(t); a += ["-O", "forward", t.kind.flag, t.specArgument]
        case .cancel(let t): try Self.validate(t); a += ["-O", "cancel", t.kind.flag, t.specArgument]
        }
        return a + ["--", profile.target]
    }

    /// Shell interactif sur le maître. `remoteCommand` (optionnel) est UNE chaîne interprétée par le shell distant,
    /// comme le veut ssh : l'appelant en est responsable.
    public func shellArguments(remoteCommand: String? = nil) -> [String] {
        var a = secondaryPrefix() + ["-tt"] + targetOptions() + ["--", profile.target]
        if let c = remoteCommand { a.append(c) }
        return a
    }

    /// Canal SFTP : `ssh -S … -s <cible> sftp`. `verbose` ajoute `-v` (permet de savoir quand le maître a ouvert la session).
    public func sftpArguments(verbose: Bool = false) -> [String] {
        secondaryPrefix() + (verbose ? ["-v"] : []) + targetOptions() + ["-s", "--", profile.target, "sftp"]
    }

    /// Environnement à ajouter pour tout processus ssh (askpass prévu, non implémenté ici).
    public var environment: [String: String] { options.environment }

    // MARK: - Interne

    /// Invariant 2 : tout client secondaire neutralise le repli sur une nouvelle connexion.
    func secondaryPrefix() -> [String] {
        var a = ["-S", controlPath, "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false"]
        if let f = options.configFile { a += ["-F", f] }
        return a
    }

    func targetOptions() -> [String] {
        var a: [String] = []
        if let p = profile.port { a += ["-p", String(p)] }
        if case .keyFile(let path) = profile.auth { a += ["-i", path, "-o", "IdentitiesOnly=yes"] }
        return a
    }

    private static func hasControlOrNul(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private static func validateHostLike(_ s: String, error: (String) -> OpenSSHCommandBuilderError) throws {
        if s.isEmpty || s.hasPrefix("-") || hasControlOrNul(s) || s.contains(where: \.isWhitespace) { throw error(s) }
    }

    private static func validate(_ t: TunnelSpec) throws {
        func bad(_ why: String) -> OpenSSHCommandBuilderError { .invalidTunnel(why) }
        guard (1...65535).contains(t.bindPort) else { throw bad("port local \(t.bindPort)") }
        if hasControlOrNul(t.bindAddress) || t.bindAddress.contains(where: \.isWhitespace) { throw bad("adresse locale") }
        if t.kind != .dynamic {
            guard (1...65535).contains(t.destinationPort) else { throw bad("port destination \(t.destinationPort)") }
            if t.destinationHost.isEmpty || hasControlOrNul(t.destinationHost) || t.destinationHost.contains(where: \.isWhitespace) {
                throw bad("hôte destination")
            }
        }
    }
}
