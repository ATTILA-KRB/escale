import Foundation

/// Commande distante en flux binaire (stdin/stdout), au-dessus de `ssh -T` sur le maître. Contrairement à
/// `OpenSSHTransport.exec` (sortie décodée en texte), les octets passent tels quels : transferts `cat` / `dd`.
///
/// Un seul lecteur et un seul écrivain à la fois. Les E/S bloquantes tournent sur des files dédiées (jamais sur
/// le pool coopératif) ; `cancel()` tue le processus, ce qui débloque lecture et écriture. `finish()` (ou `cancel()`)
/// doit toujours être appelé : il libère la place dans le plafond de sessions du maître (invariant 5).
public final class RemoteExecStream: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "escale.exec.stream.write")
    private let lock = NSLock()
    private var stderrData = Data()
    private var exitStatus: Int32?
    private var exited = false
    private var cancelled = false
    private var inputClosed = false   // modifié sur writeQueue
    private var onEnd: (@Sendable () -> Void)?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Lance le processus. `onEnd` est appelé une seule fois, quand le processus a fini.
    init(executable: String, arguments: [String], environment: [String: String],
         onEnd: (@Sendable () -> Void)? = nil) throws {
        self.onEnd = onEnd
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, n in n }
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.appendStderr(d)
        }
        process.terminationHandler = { [weak self] p in self?.didExit(status: p.terminationStatus) }
        do { try process.run() } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Le processus n'a jamais existé : pas d'arrêt à attendre, mais la place doit être rendue.
            let cb = self.onEnd; self.onEnd = nil
            cb?()
            throw error
        }
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    deinit {
        if process.isRunning { process.terminate() }
        try? stdinPipe.fileHandleForWriting.close()
    }

    private func appendStderr(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        stderrData.append(d)
        if stderrData.count > 65_536 { stderrData = stderrData.suffix(32_768) }
    }

    private func didExit(status: Int32) {
        lock.lock()
        exited = true; exitStatus = status
        let waiters = exitWaiters; exitWaiters = []
        let cb = onEnd; onEnd = nil
        lock.unlock()
        cb?()
        for w in waiters { w.resume() }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Lit au plus `maxBytes` octets de stdout ; vide en fin de flux.
    public func read(maxBytes: Int) async throws -> Data {
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        let result: Result<Data, ByteChannelError> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var buf = [UInt8](repeating: 0, count: max(1, maxBytes))
                var idle = 0
                while true {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let n = poll(&pfd, 1, 100)
                    if n > 0 {
                        let r = Darwin.read(fd, &buf, buf.count)
                        if r > 0 { cont.resume(returning: .success(Data(buf[0..<r]))); return }
                        if r == 0 { cont.resume(returning: .success(Data())); return }
                        if errno == EINTR { continue }
                        cont.resume(returning: .failure(.closed(reason: "lecture impossible (errno \(errno))"))); return
                    }
                    if isCancelled { cont.resume(returning: .failure(.closed(reason: "flux annulé"))); return }
                    // ssh mort mais tube non fermé (le maître garde les descripteurs reçus) : fin de flux.
                    if !lock.withLock({ exited }) { idle = 0 } else { idle += 1; if idle >= 2 { cont.resume(returning: .success(Data())); return } }
                }
            }
        }
        return try result.get()
    }

    /// Lit tout stdout (borné par `limit` octets : au-delà, erreur).
    public func readAll(limit: Int = 256 * 1024 * 1024) async throws -> Data {
        var out = Data()
        while true {
            let d = try await read(maxBytes: 256 * 1024)
            if d.isEmpty { return out }
            out.append(d)
            if out.count > limit { cancel(); throw ByteChannelError.closed(reason: "sortie distante trop grande") }
        }
    }

    /// Écrit sur stdin (bloquant sur une file dédiée). Échoue si le processus est mort.
    public func write(_ data: Data) async throws {
        if data.isEmpty { return }
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        let err: Int32 = await withCheckedContinuation { cont in
            writeQueue.async { [self] in
                if inputClosed { cont.resume(returning: EPIPE); return }
                var result: Int32 = 0
                data.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                        if n < 0 { if errno == EINTR { continue }; result = errno; return }
                        off += n
                    }
                }
                cont.resume(returning: result)
            }
        }
        if err != 0 { throw ByteChannelError.closed(reason: "écriture impossible (errno \(err))") }
    }

    /// Ferme stdin (la commande distante voit la fin de fichier), après les écritures en cours.
    public func closeInput() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async { [self] in
                if !inputClosed { inputClosed = true; try? stdinPipe.fileHandleForWriting.close() }
                cont.resume()
            }
        }
    }

    /// Interrompt la commande (SIGTERM, puis SIGKILL si besoin).
    public func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                if let self, self.process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// Attend la fin du processus (ferme stdin d'abord). `exitCode` est nil si la commande a été annulée.
    public func finish(timeout: TimeInterval = 30) async -> (exitCode: Int32?, stderr: String) {
        await closeInput()
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.cancel()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited { lock.unlock(); cont.resume(); return }
            exitWaiters.append(cont)
            lock.unlock()
        }
        watchdog.cancel()
        // Laisse le gestionnaire de stderr livrer les derniers octets.
        try? await Task.sleep(for: .milliseconds(20))
        let (st, was, err) = lock.withLock { (exitStatus, cancelled, stderrData) }
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return (was ? nil : st, String(decoding: err, as: UTF8.self))
    }
}

/// Exécuteur de commandes shell distantes : texte (`runShell`, résultat décodé) ou flux binaire (`openShellStream`).
/// `OpenSSHTransport` l'implémente (sessions exec comptées dans `sessionCount`) ; les tests utilisent `/bin/sh` en local.
public protocol ShellExecutor: Sendable {
    func runShell(_ command: String, timeout: TimeInterval, maxOutputBytes: Int) async throws -> RemoteExecResult
    func openShellStream(_ command: String) async throws -> RemoteExecStream
}

extension OpenSSHCommandBuilder {
    /// Commande distante en flux : comme `batchExecArguments` mais stdin reste ouvert (pas de `-n`).
    /// Invariant 2 : préfixe secondaire (`ControlMaster=no`, `ProxyCommand=/usr/bin/false`).
    public func batchStreamArguments(remoteCommand: String) -> [String] {
        secondaryPrefix() + ["-T", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR"] + targetOptions()
            + ["--", profile.target, remoteCommand]
    }
}

extension OpenSSHTransport: ShellExecutor {
    public func runShell(_ command: String, timeout: TimeInterval, maxOutputBytes: Int) async throws -> RemoteExecResult {
        try await exec(command, timeout: timeout, maxOutputBytes: maxOutputBytes)
    }

    /// Ouvre une commande en flux sur la connexion existante. Compte une session (plafond, invariant 5) jusqu'à la fin
    /// du processus. Lève `notConnected` / `sessionRefused`.
    public func openShellStream(_ command: String) async throws -> RemoteExecStream {
        guard await isAlive() else { throw SSHTransportError.notConnected }
        guard sessionCount < configuration.maxSessions else {
            throw SSHTransportError.sessionRefused("plafond local de \(configuration.maxSessions) sessions atteint")
        }
        let b = try makeBuilder()
        execSessions += 1
        do {
            return try RemoteExecStream(
                executable: configuration.ssh.sshPath, arguments: b.batchStreamArguments(remoteCommand: command),
                environment: configuration.ssh.environment.merging(b.environment) { _, n in n },
                onEnd: { [weak self] in Task { await self?.execStreamEnded() } })
        } catch {
            // `onEnd` a déjà rendu la place (Task asynchrone) : rien d'autre à défaire ici.
            throw SSHTransportError.sessionRefused("lancement de ssh impossible : \(error)")
        }
    }

    func execStreamEnded() { execSessions = max(0, execSessions - 1) }
}
