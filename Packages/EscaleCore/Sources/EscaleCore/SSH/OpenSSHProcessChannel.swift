import Foundation

/// `ByteChannel` adossé aux pipes d'un processus `ssh -s … sftp`.
/// Lecture exacte asynchrone : les octets arrivent par `readabilityHandler` (aucun thread du pool coopératif bloqué),
/// les écritures passent par une file série dédiée (un pipe plein ne bloque jamais le pool).
final class OpenSSHProcessChannel: ByteChannel, @unchecked Sendable {
    enum SessionOutcome: Sendable, Equatable {
        /// Le maître a ouvert la session (ou la confirmation n'est pas arrivée dans le délai : on suppose ouverte).
        case established
        /// Le processus s'est terminé avant confirmation ; `stderr` filtré.
        case failed(stderr: String, status: Int32)
    }

    let id = UUID()
    private let process = Process()
    private let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "escale.openssh.channel.write")

    private var buffer = Data()
    private var stderrBuffer = Data()
    private var stdoutEOF = false, stderrEOF = false
    private var exited = false
    private var status: Int32 = 0
    private var closedLocally = false
    private var stdinClosed = false   // modifié uniquement sur writeQueue
    private var waiters: [(count: Int, cont: CheckedContinuation<Data, Error>)] = []
    private var onClose: (@Sendable (UUID) -> Void)?
    private var closeNotified = false

    /// Lance le processus. Lève si le lancement échoue.
    init(executable: String, arguments: [String], environment: [String: String], onClose: @escaping @Sendable (UUID) -> Void) throws {
        self.onClose = onClose
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if d.isEmpty { h.readabilityHandler = nil }
            self.receive(stdout: d)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if d.isEmpty { h.readabilityHandler = nil }
            self.receive(stderr: d)
        }
        process.terminationHandler = { [weak self] p in
            self?.processDidExit(status: p.terminationStatus)
        }
        do { try process.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        // Évite SIGPIPE si ssh meurt pendant une écriture : l'erreur EPIPE est retournée à la place.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    var processIdentifier: Int32 { process.processIdentifier }

    // MARK: - Réception

    private func receive(stdout d: Data) {
        lock.lock()
        if d.isEmpty { stdoutEOF = true } else { buffer.append(d) }
        let (toResume, toFail) = pumpLocked(force: false)
        lock.unlock()
        deliver(toResume, toFail)
        if d.isEmpty { scheduleForcedPump() }
    }

    private func receive(stderr d: Data) {
        lock.lock()
        if d.isEmpty { stderrEOF = true } else {
            stderrBuffer.append(d)
            if stderrBuffer.count > 65_536 { stderrBuffer = stderrBuffer.suffix(32_768) }
        }
        let (toResume, toFail) = pumpLocked(force: false)
        lock.unlock()
        deliver(toResume, toFail)
    }

    private func processDidExit(status s: Int32) {
        lock.lock(); exited = true; status = s; lock.unlock()
        notifyClosed()
        scheduleForcedPump()
    }

    /// Si stderr tarde à se fermer, on ne bloque pas les lecteurs indéfiniment.
    private func scheduleForcedPump() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let (r, f) = self.pumpLocked(force: true)
            self.lock.unlock()
            self.deliver(r, f)
        }
    }

    private func notifyClosed() {
        lock.lock()
        let cb = closeNotified ? nil : onClose
        closeNotified = true; onClose = nil
        lock.unlock()
        cb?(id)
    }

    /// Sert les lecteurs satisfaits ; si le flux est fini, échoue les autres. À appeler verrou pris.
    private func pumpLocked(force: Bool) -> ([(CheckedContinuation<Data, Error>, Data)], [CheckedContinuation<Data, Error>]) {
        var ok: [(CheckedContinuation<Data, Error>, Data)] = []
        while let w = waiters.first, buffer.count >= w.count {
            ok.append((w.cont, buffer.prefix(w.count)))
            buffer.removeFirst(w.count)
            waiters.removeFirst()
        }
        var fail: [CheckedContinuation<Data, Error>] = []
        let streamEnded = stdoutEOF && (stderrEOF || force)
        if !waiters.isEmpty && (streamEnded || (closedLocally && stdoutEOF)) {
            fail = waiters.map(\.cont); waiters.removeAll()
        }
        return (ok, fail)
    }

    private func deliver(_ ok: [(CheckedContinuation<Data, Error>, Data)], _ fail: [CheckedContinuation<Data, Error>]) {
        for (c, d) in ok { c.resume(returning: d) }
        if !fail.isEmpty {
            let reason = closedReason()
            for c in fail { c.resume(throwing: ByteChannelError.closed(reason: reason)) }
        }
    }

    /// Cause de la fermeture : stderr de ssh (sans le bruit `debug1:`), sinon le code de sortie.
    func closedReason() -> String {
        lock.lock()
        let text = String(decoding: stderrBuffer, as: UTF8.self)
        let local = closedLocally, st = status, ex = exited
        lock.unlock()
        let lines = OpenSSHJournal.meaningfulLines(text)
        if !lines.isEmpty { return lines.suffix(3).joined(separator: " | ") }
        if local { return "canal fermé localement" }
        return ex ? "ssh terminé (code \(st))" : "flux fermé"
    }

    // MARK: - ByteChannel

    func read(exactly count: Int) async throws -> Data {
        if count <= 0 { return Data() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            waiters.append((count, cont))
            let (ok, fail) = pumpLocked(force: false)
            lock.unlock()
            deliver(ok, fail)
            // Flux déjà terminé avant cet appel : les handlers ne se redéclencheront pas.
            lock.lock(); let ended = stdoutEOF && !waiters.isEmpty; lock.unlock()
            if ended { scheduleForcedPump() }
        }
    }

    func write(_ data: Data) async throws {
        if data.isEmpty { return }
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        let err: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            writeQueue.async { [self] in
                if stdinClosed { cont.resume(returning: EPIPE); return }
                var result: Int32 = 0
                data.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                        if n < 0 {
                            if errno == EINTR { continue }
                            result = errno; return
                        }
                        off += n
                    }
                }
                cont.resume(returning: result)
            }
        }
        if err != 0 { throw ByteChannelError.closed(reason: await reasonAfterFailure()) }
    }

    /// Laisse à ssh le temps d'écrire la cause sur stderr avant de la reporter.
    private func reasonAfterFailure() async -> String {
        for _ in 0..<20 {
            let done = lock.withLock { stderrEOF || exited }
            if done { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return closedReason()
    }

    func close() async {
        lock.withLock { closedLocally = true }
        // La fermeture de stdin est sérialisée avec les écritures (pas de réutilisation du descripteur).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async { [self] in
                if !stdinClosed { stdinClosed = true; try? stdinPipe.fileHandleForWriting.close() }
                cont.resume()
            }
        }
        await waitForExit(seconds: 1.0)
        if process.isRunning { process.terminate(); await waitForExit(seconds: 1.0) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); await waitForExit(seconds: 1.0) }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let (ok, fail) = lock.withLock { () -> ([(CheckedContinuation<Data, Error>, Data)], [CheckedContinuation<Data, Error>]) in
            stdoutEOF = true; stderrEOF = true
            return pumpLocked(force: true)
        }
        deliver(ok, fail)
        notifyClosed()
    }

    private func waitForExit(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - Ouverture de session

    /// Attend la confirmation du maître (`-v` : « master session id ») ou la mort du processus.
    func waitForSessionOutcome(timeout: TimeInterval) async -> SessionOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (text, ex, st, eof) = lock.withLock { (String(decoding: stderrBuffer, as: UTF8.self), exited, status, stderrEOF) }
            if text.contains("master session id") { return .established }
            if ex || process.isRunning == false {
                // Laisse stderr se vider complètement avant de classer l'échec.
                if eof || !process.isRunning { try? await Task.sleep(for: .milliseconds(30)) }
                let t = lock.withLock { String(decoding: stderrBuffer, as: UTF8.self) }
                if t.contains("master session id") { return .established }
                let filtered = OpenSSHJournal.meaningfulLines(t).joined(separator: " | ")
                return .failed(stderr: filtered, status: process.isRunning ? st : process.terminationStatus)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return .established
    }
}
