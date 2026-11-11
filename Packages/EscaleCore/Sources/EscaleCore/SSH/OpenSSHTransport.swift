import Foundation

/// Transport SSH de production : `/usr/bin/ssh` + ControlMaster.
/// Un processus maître authentifie une fois ; shells, SFTP et tunnels le réutilisent sans nouvelle authentification.
public actor OpenSSHTransport: SSHTransport {
    public struct Configuration: Sendable {
        public var ssh: OpenSSHOptions
        /// Chemin complet du socket de contrôle. Si nil : un dossier 0700 dédié est créé sous `socketDirectory`.
        public var controlPath: String?
        /// Dossier parent du dossier dédié (défaut : `NSTemporaryDirectory()`, repli sur `/tmp` si le chemin est trop long).
        public var socketDirectory: String?
        /// Délai maximal d'attente de disponibilité du maître (authentification comprise).
        public var masterReadyTimeout: TimeInterval
        /// Plafond local de sessions (shells + SFTP) sur ce maître ; invariant 5 : 10 au plus.
        public var maxSessions: Int
        /// Sonde du port local après `-O forward` (connecte brièvement la cible du tunnel pour prouver le canal).
        public var probeForwards: Bool
        /// Fenêtre d'observation d'un rejet de canal après la sonde d'un tunnel local.
        public var forwardProbeTimeout: TimeInterval
        /// Délai d'attente de la confirmation d'ouverture d'une session par le maître.
        public var sessionOpenTimeout: TimeInterval
        /// Authentification interactive (mot de passe, phrase de passe, 2FA, clé d'hôte) via askpass. nil : `BatchMode`, comme avant.
        public var askpass: AskpassConfiguration?

        public init(
            ssh: OpenSSHOptions = OpenSSHOptions(), controlPath: String? = nil, socketDirectory: String? = nil,
            masterReadyTimeout: TimeInterval = 20, maxSessions: Int = 10, probeForwards: Bool = true,
            forwardProbeTimeout: TimeInterval = 1.0, sessionOpenTimeout: TimeInterval = 5,
            askpass: AskpassConfiguration? = nil
        ) {
            self.ssh = ssh; self.controlPath = controlPath; self.socketDirectory = socketDirectory
            self.masterReadyTimeout = masterReadyTimeout; self.maxSessions = maxSessions
            self.probeForwards = probeForwards; self.forwardProbeTimeout = forwardProbeTimeout
            self.sessionOpenTimeout = sessionOpenTimeout; self.askpass = askpass
        }
    }

    /// Longueur maximale (octets) du chemin du socket : sun_path vaut 104, ssh ajoute ~17 octets de suffixe temporaire.
    public static let maxControlPathBytes = 80

    public nonisolated let profile: HostProfile
    public nonisolated let configuration: Configuration

    private var master: Process?
    private var connectTask: Task<Void, Error>?
    private var paths: (socket: String, log: String, ownedDirectory: String?)?
    private var channels: [UUID: OpenSSHProcessChannel] = [:]
    private var shellSessions = 0
    /// Commandes non interactives en cours (module multi-exécution) : comptées pour le plafond, voir `exec`.
    var execSessions = 0
    private var tunnels: Set<TunnelSpec> = []
    private var askpassServer: AskpassServer?

    public init(profile: HostProfile, configuration: Configuration = Configuration()) {
        self.profile = profile
        self.configuration = configuration
    }

    // MARK: - API publique complémentaire

    /// Chemin du socket de contrôle une fois connecté (ou préparé).
    public var controlSocketPath: String? { paths?.socket }

    /// Nombre de sessions ouvertes sur ce maître par ce transport (canaux SFTP + shells déclarés).
    public var sessionCount: Int { channels.count + shellSessions }

    /// PID du processus maître (nil si non connecté).
    public var masterProcessIdentifier: Int32? { master.flatMap { $0.isRunning ? $0.processIdentifier : nil } }

    /// Tunnels actuellement actifs et vérifiés.
    public var activeTunnels: Set<TunnelSpec> { tunnels }

    /// Socket du serveur askpass tant que la connexion vit (nil sans askpass, ou déconnecté).
    public var askpassSocketPath: String? { get async { await askpassServer?.socketPath } }

    /// Journal (stderr) du maître : messages ssh, refus de forwarding (`open failed: …`), etc.
    public func masterJournal() -> String {
        guard let log = paths?.log else { return "" }
        return (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    }

    /// À appeler quand un shell obtenu par `shellCommand()` se termine (libère une place du plafond local).
    public func shellSessionDidEnd() { shellSessions = max(0, shellSessions - 1) }

    // MARK: - Connexion

    public func connect() async throws {
        if let task = connectTask { return try await task.value }
        if let m = master, m.isRunning, await masterResponds() { return }
        let task = Task { try await self.performConnect() }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    private func performConnect() async throws {
        guard let ask = configuration.askpass else {
            try await launchMaster(builder: try makeBuilder(), server: nil)
            return
        }
        // Un serveur (et un jeton) neufs par connexion maître ; il vit jusqu'à `disconnect()`.
        if let old = askpassServer { await old.stop(); askpassServer = nil }
        let server = AskpassServer(responder: ask.responder, limits: ask.limits, socketDirectory: ask.socketDirectory)
        do { _ = try await server.start() } catch { throw SSHTransportError.masterFailed("serveur askpass indisponible : \(error)") }
        askpassServer = server
        do {
            var options = configuration.ssh
            options.batchMode = false   // sinon ssh n'appelle jamais askpass
            for (k, v) in try await server.environment(askpassExecutable: ask.executablePath) { options.environment[k] = v }
            let p = try preparePaths()
            let builder: OpenSSHCommandBuilder
            do { builder = try OpenSSHCommandBuilder(profile: profile, controlPath: p.socket, options: options) }
            catch { throw SSHTransportError.masterFailed("paramètres invalides : \(error)") }
            try await launchMaster(builder: builder, server: server)
            await ask.responder.authenticationSucceeded()
        } catch {
            let mapped = await mapAuthenticationFailure(error, server: server)
            await server.stop()
            askpassServer = nil
            await ask.responder.authenticationFailed()
            throw mapped
        }
    }

    /// Type l'échec d'un maître authentifié par askpass : annulation, clé d'hôte, secret refusé, délai.
    private func mapAuthenticationFailure(_ error: Error, server: AskpassServer) async -> Error {
        guard case SSHTransportError.masterFailed(let message) = error else { return error }
        let outcome = await server.outcome
        let journal = masterJournal()
        let lower = journal.lowercased()
        // ssh n'appelle pas askpass pour une clé modifiée : seul son journal le dit.
        if outcome.hostKeyChanged || lower.contains("remote host identification has changed")
            || (lower.contains("host key for") && lower.contains("has changed")) {
            let line = OpenSSHJournal.meaningfulLines(journal).last { $0.lowercased().contains("has changed") }
            return SSHAuthenticationError.hostKeyChanged(line ?? message)
        }
        if outcome.timedOut { return SSHAuthenticationError.timedOut }
        if outcome.hostKeyRejected { return SSHAuthenticationError.hostKeyRejected }
        if outcome.cancelled { return SSHAuthenticationError.cancelled }
        if outcome.secretProvided && message.contains("Permission denied") { return SSHAuthenticationError.wrongSecret(message) }
        return error
    }

    private func launchMaster(builder: OpenSSHCommandBuilder, server: AskpassServer?) async throws {
        let p = try preparePaths()
        if let old = master { await terminate(old) ; master = nil }
        // Un maître neuf n'a aucun forwarding : sans cela, un tunnel de l'ancien maître (mort sans que `isAlive()` l'ait
        // constaté) serait cru encore ouvert et jamais rouvert.
        tunnels.removeAll()

        // Un maître étranger répond déjà sur ce socket : ne pas l'écraser.
        if FileManager.default.fileExists(atPath: p.socket), await masterResponds() {
            throw SSHTransportError.masterFailed("un maître répond déjà sur \(p.socket)")
        }
        // Invariant 3 : supprimer un socket mort, sinon `ssh -M` se replie en silence sans maître.
        try? FileManager.default.removeItem(atPath: p.socket)

        guard FileManager.default.createFile(atPath: p.log, contents: nil, attributes: [.posixPermissions: 0o600]),
              let logHandle = FileHandle(forWritingAtPath: p.log)
        else { throw SSHTransportError.masterFailed("impossible de créer le journal \(p.log)") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.ssh.sshPath)
        process.arguments = builder.masterArguments()
        process.environment = ProcessInfo.processInfo.environment.merging(builder.environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        do { try process.run() } catch {
            try? logHandle.close()
            throw SSHTransportError.masterFailed("lancement de ssh impossible : \(error)")
        }
        try? logHandle.close()
        master = process

        var deadline = Date().addingTimeInterval(configuration.masterReadyTimeout)
        while Date() < deadline {
            // L'attente d'une saisie utilisateur ne consomme pas le délai de connexion.
            if let server, await server.pendingPromptCount > 0 {
                deadline = Date().addingTimeInterval(configuration.masterReadyTimeout)
            }
            if !process.isRunning {
                let journal = masterJournal()
                let msg = OpenSSHJournal.lastError(journal) ?? "ssh a quitté avec le code \(process.terminationStatus)"
                master = nil
                try? FileManager.default.removeItem(atPath: p.socket)
                throw SSHTransportError.masterFailed(msg)
            }
            if FileManager.default.fileExists(atPath: p.socket), await masterResponds(), process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await terminate(process)
        master = nil
        try? FileManager.default.removeItem(atPath: p.socket)
        let detail = OpenSSHJournal.lastError(masterJournal()).map { " (\($0))" } ?? ""
        throw SSHTransportError.masterFailed("maître non disponible après \(Int(configuration.masterReadyTimeout)) s\(detail)")
    }

    public func isAlive() async -> Bool {
        guard let m = master else { return false }
        guard m.isRunning else { handleMasterDeath(); return false }
        return await masterResponds()
    }

    public func disconnect() async {
        for c in Array(channels.values) { await c.close() }
        channels.removeAll(); shellSessions = 0; tunnels.removeAll()
        if let m = master {
            if m.isRunning, let b = try? makeBuilder(), let args = try? b.controlArguments(.exit) {
                _ = await run(args, timeout: 3)
            }
            await terminate(m)
            master = nil
        }
        if let server = askpassServer { await server.stop(); askpassServer = nil }
        if let p = paths {
            try? FileManager.default.removeItem(atPath: p.socket)
            try? FileManager.default.removeItem(atPath: p.log)
            if let dir = p.ownedDirectory { try? FileManager.default.removeItem(atPath: dir) }
        }
        paths = nil
    }

    // MARK: - Shell et SFTP

    public func shellCommand() async throws -> ShellCommand { try await shellCommand(remoteCommand: nil) }

    /// Shell (ou commande distante unique, interprétée par le shell distant) sur la connexion existante.
    public func shellCommand(remoteCommand: String?) async throws -> ShellCommand {
        guard await isAlive() else { throw SSHTransportError.notConnected }
        guard sessionCount < configuration.maxSessions else {
            throw SSHTransportError.sessionRefused("plafond local de \(configuration.maxSessions) sessions atteint")
        }
        let b = try makeBuilder()
        shellSessions += 1
        return ShellCommand(
            executable: configuration.ssh.sshPath, arguments: b.shellArguments(remoteCommand: remoteCommand),
            environment: b.environment)
    }

    /// Commande distante sans terminal sur la connexion existante (applications X11). Compte comme une session du maître :
    /// l'appelant appelle `shellSessionDidEnd()` à la fin du processus.
    public func execCommand(remoteCommand: String) async throws -> ShellCommand {
        guard await isAlive() else { throw SSHTransportError.notConnected }
        guard sessionCount < configuration.maxSessions else {
            throw SSHTransportError.sessionRefused("plafond local de \(configuration.maxSessions) sessions atteint")
        }
        let b = try makeBuilder()
        shellSessions += 1
        return ShellCommand(
            executable: configuration.ssh.sshPath, arguments: b.execArguments(remoteCommand: remoteCommand),
            environment: b.environment)
    }

    public func openSFTPChannel() async throws -> any ByteChannel {
        guard await isAlive() else { throw SSHTransportError.notConnected }
        guard sessionCount < configuration.maxSessions else {
            throw SSHTransportError.sessionRefused("plafond local de \(configuration.maxSessions) sessions atteint")
        }
        let b = try makeBuilder()
        let channel: OpenSSHProcessChannel
        do {
            channel = try OpenSSHProcessChannel(
                executable: configuration.ssh.sshPath, arguments: b.sftpArguments(verbose: true),
                environment: b.environment,
                onClose: { [weak self] id in Task { await self?.channelClosed(id) } })
        } catch {
            throw SSHTransportError.subsystemUnavailable("lancement de ssh impossible : \(error)")
        }
        channels[channel.id] = channel
        switch await channel.waitForSessionOutcome(timeout: configuration.sessionOpenTimeout) {
        case .established:
            return channel
        case .failed(let stderr, let status):
            await channel.close()
            channels[channel.id] = nil
            let msg = stderr.isEmpty ? "ssh terminé (code \(status))" : stderr
            let lower = msg.lowercased()
            if lower.contains("refused by peer") || lower.contains("session open refused") {
                throw SSHTransportError.sessionRefused(msg)
            }
            if lower.contains("control socket") || lower.contains("mux_client") && lower.contains("connect") {
                throw SSHTransportError.notConnected
            }
            throw SSHTransportError.subsystemUnavailable(msg)
        }
    }

    private func channelClosed(_ id: UUID) { channels[id] = nil }

    // MARK: - Tunnels

    public func addTunnel(_ tunnel: TunnelSpec) async throws {
        guard await isAlive() else { throw SSHTransportError.notConnected }
        if tunnels.contains(tunnel) { return }
        let b = try makeBuilder()
        let before = masterJournal().utf8.count
        let r = await run(try b.controlArguments(.forward(tunnel)), timeout: 10)
        let text = r.combined
        // Invariant 4 : le code 0 ne prouve rien ; on vérifie réellement.
        if r.status != 0 || r.timedOut || Self.looksLikeForwardError(text) {
            throw SSHTransportError.forwardRefused(text.isEmpty ? "ssh -O forward a échoué (code \(r.status))" : text)
        }
        if configuration.probeForwards {
            switch tunnel.kind {
            case .local:
                let outcome = await OpenSSHPortProbe.probe(host: tunnel.bindAddress, port: tunnel.bindPort, observe: configuration.forwardProbeTimeout)
                try await verifyLocalProbe(outcome, tunnel: tunnel, journalOffset: before, builder: b)
            case .dynamic:
                let outcome = await OpenSSHPortProbe.probe(host: tunnel.bindAddress, port: tunnel.bindPort, observe: 0)
                if outcome == .closed {
                    try? await cancelQuietly(tunnel, builder: b)
                    throw SSHTransportError.forwardRefused("le port local \(tunnel.bindPort) n'écoute pas après -O forward")
                }
            case .remote:
                break // rien à sonder localement : seul le message de ssh (vérifié ci-dessus) renseigne.
            }
        }
        tunnels.insert(tunnel)
    }

    public func removeTunnel(_ tunnel: TunnelSpec) async throws {
        guard await isAlive() else { throw SSHTransportError.notConnected }
        let b = try makeBuilder()
        let r = await run(try b.controlArguments(.cancel(tunnel)), timeout: 10)
        if tunnel.kind != .remote {
            // Le port local doit réellement avoir cessé d'écouter (quelques essais : fermeture côté maître asynchrone).
            for attempt in 0..<10 {
                if await OpenSSHPortProbe.probe(host: tunnel.bindAddress, port: tunnel.bindPort, observe: 0) == .closed {
                    tunnels.remove(tunnel); return
                }
                if attempt < 9 { try? await Task.sleep(for: .milliseconds(50)) }
            }
            let msg = r.combined
            throw SSHTransportError.forwardRefused(msg.isEmpty ? "le port local \(tunnel.bindPort) écoute encore après -O cancel" : msg)
        }
        if r.status != 0 || r.timedOut || Self.looksLikeForwardError(r.combined) {
            throw SSHTransportError.forwardRefused(r.combined)
        }
        tunnels.remove(tunnel)
    }

    private func verifyLocalProbe(_ outcome: OpenSSHPortProbe.Outcome, tunnel: TunnelSpec, journalOffset: Int, builder: OpenSSHCommandBuilder) async throws {
        // Laisse au maître le temps de journaliser un éventuel rejet.
        if outcome == .rejected { try? await Task.sleep(for: .milliseconds(100)) }
        let journal = String(decoding: Array(masterJournal().utf8.dropFirst(journalOffset)), as: UTF8.self)
        let refusalLine = OpenSSHJournal.meaningfulLines(journal).last {
            $0.contains("open failed") || $0.contains("administratively prohibited") || $0.contains("connect failed")
        }
        switch outcome {
        case .closed:
            try? await cancelQuietly(tunnel, builder: builder)
            throw SSHTransportError.forwardRefused("le port local \(tunnel.bindPort) n'écoute pas après -O forward")
        case .rejected:
            try? await cancelQuietly(tunnel, builder: builder)
            throw SSHTransportError.forwardRefused(refusalLine ?? "canal de forwarding rejeté (connexion fermée aussitôt)")
        case .open:
            if let refusalLine {
                try? await cancelQuietly(tunnel, builder: builder)
                throw SSHTransportError.forwardRefused(refusalLine)
            }
        }
    }

    private func cancelQuietly(_ tunnel: TunnelSpec, builder: OpenSSHCommandBuilder) async throws {
        _ = await run(try builder.controlArguments(.cancel(tunnel)), timeout: 5)
    }

    private static func looksLikeForwardError(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["cannot listen", "could not request", "forwarding failed", "address already in use", "not forwarded",
                "administratively prohibited", "permission denied", "failed"].contains { t.contains($0) }
    }

    // MARK: - Interne

    func makeBuilder() throws -> OpenSSHCommandBuilder {
        let p = try preparePaths()
        do { return try OpenSSHCommandBuilder(profile: profile, controlPath: p.socket, options: configuration.ssh) }
        catch { throw SSHTransportError.masterFailed("paramètres invalides : \(error)") }
    }

    /// Calcule (une fois) le socket et le journal ; crée le dossier 0700 dédié si nécessaire.
    @discardableResult
    private func preparePaths() throws -> (socket: String, log: String, ownedDirectory: String?) {
        if let p = paths { return p }
        let fm = FileManager.default
        let result: (String, String, String?)
        if let explicit = configuration.controlPath {
            guard explicit.utf8.count <= Self.maxControlPathBytes else {
                throw SSHTransportError.masterFailed("chemin de socket trop long (\(explicit.utf8.count) octets, maximum \(Self.maxControlPathBytes))")
            }
            result = (explicit, explicit + ".log", nil)
        } else {
            let token = UUID().uuidString.prefix(8).lowercased()
            var base = configuration.socketDirectory ?? NSTemporaryDirectory()
            while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
            var dir = "\(base)/escale-\(token)"
            if "\(dir)/m".utf8.count > Self.maxControlPathBytes { dir = "/tmp/escale-\(token)" }
            do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw SSHTransportError.masterFailed("création du dossier de socket impossible : \(error)") }
            result = ("\(dir)/m", "\(dir)/master.log", dir)
        }
        paths = result
        return result
    }

    private func masterResponds() async -> Bool {
        guard let b = try? makeBuilder(), let args = try? b.controlArguments(.check) else { return false }
        return await run(args, timeout: 3).status == 0
    }

    private func run(_ args: [String], timeout: TimeInterval) async -> OpenSSHRunResult {
        await OpenSSHProcessRunner.run(
            executable: configuration.ssh.sshPath, arguments: args, environment: configuration.ssh.environment, timeout: timeout)
    }

    /// Le maître est mort (SIGKILL, réseau…) : son socket est orphelin, ses tunnels et canaux n'existent plus.
    private func handleMasterDeath() {
        master = nil
        tunnels.removeAll()
        if let s = paths?.socket { try? FileManager.default.removeItem(atPath: s) }
    }

    /// Arrêt progressif : attente, SIGTERM, puis SIGKILL en dernier recours.
    private func terminate(_ p: Process) async {
        await waitExit(p, seconds: 1.5)
        if p.isRunning { p.terminate(); await waitExit(p, seconds: 1.5) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL); await waitExit(p, seconds: 1.5) }
    }

    private func waitExit(_ p: Process, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
