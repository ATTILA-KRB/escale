import Foundation

/// Résultat d'une commande distante non interactive (un `ssh -T <cible> <commande>` sur le maître).
public struct RemoteExecResult: Sendable, Equatable {
    /// Code de sortie de la commande distante ; nil si elle n'a pas pu s'exécuter ou a été interrompue (délai).
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String
    /// Vrai si la sortie a dépassé la limite et a été coupée (le reste est lu puis ignoré).
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var duration: TimeInterval
    /// Délai maximal atteint : ssh a été interrompu.
    public var timedOut: Bool
    /// Échec avant ou hors de la commande (connexion absente, plafond de sessions, erreur de ssh) : message français.
    public var failure: String?

    public init(
        exitCode: Int32? = nil, stdout: String = "", stderr: String = "", stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false, duration: TimeInterval = 0, timedOut: Bool = false, failure: String? = nil
    ) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated; self.stderrTruncated = stderrTruncated
        self.duration = duration; self.timedOut = timedOut; self.failure = failure
    }

    public var isSuccess: Bool { failure == nil && !timedOut && exitCode == 0 }

    /// Résumé d'une ligne : « code 0 », « délai dépassé », message d'échec…
    public var summary: String {
        if let f = failure { return f }
        if timedOut { return "délai dépassé" }
        return exitCode.map { "code \($0)" } ?? "interrompu"
    }
}

extension OpenSSHCommandBuilder {
    /// Commande distante NON interactive sur le maître : pas de pty (`-T`), stdin fermé (`-n`), jamais d'invite.
    /// Invariant 2 : le préfixe secondaire porte `ControlMaster=no` et `ProxyCommand=/usr/bin/false`.
    /// `remoteCommand` est UNE chaîne interprétée par le shell distant, comme le veut ssh.
    public func execArguments(remoteCommand: String) -> [String] {
        secondaryPrefix() + ["-T", "-n", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR"] + targetOptions()
            + ["--", profile.target, remoteCommand]
    }
}

extension OpenSSHTransport {
    /// Commandes `exec` en cours sur ce maître.
    public var execSessionCount: Int { execSessions }

    /// Exécute `remoteCommand` sur la connexion existante (aucune nouvelle authentification), sans pty.
    /// Compte une session pendant l'exécution (invariant 5). Lève `notConnected` / `sessionRefused` ;
    /// toute autre issue (code de sortie, délai, erreur de ssh) est dans le résultat.
    public func exec(
        _ remoteCommand: String, timeout: TimeInterval = 60, maxOutputBytes: Int = 64 * 1024
    ) async throws -> RemoteExecResult {
        guard await isAlive() else { throw SSHTransportError.notConnected }
        guard sessionCount + execSessions < configuration.maxSessions else {
            throw SSHTransportError.sessionRefused("plafond local de \(configuration.maxSessions) sessions atteint")
        }
        let builder = try makeBuilder()
        execSessions += 1
        defer { execSessions -= 1 }
        let started = Date()
        var r = await BoundedProcessRunner.run(
            executable: configuration.ssh.sshPath, arguments: builder.execArguments(remoteCommand: remoteCommand),
            environment: configuration.ssh.environment.merging(builder.environment) { _, n in n },
            timeout: timeout, maxOutputBytes: max(0, maxOutputBytes))
        r.duration = Date().timeIntervalSince(started)
        // 255 : erreur de ssh lui-même (socket de contrôle disparu, session refusée par le maître…).
        if !r.timedOut, r.exitCode == 255 {
            let lower = r.stderr.lowercased()
            if lower.contains("control socket") || (lower.contains("mux_client") && lower.contains("connect")) {
                throw SSHTransportError.notConnected
            }
            if lower.contains("refused by peer") || lower.contains("session open refused") {
                throw SSHTransportError.sessionRefused(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let msg = OpenSSHJournal.lastError(r.stderr) ?? "ssh a échoué (code 255)"
            r.failure = msg
            r.exitCode = nil
        }
        return r
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

private final class ProcessRef: @unchecked Sendable {
    let process: Process
    init(_ p: Process) { process = p }
}

/// Lance un processus et lit ses sorties avec une limite d'octets (le reste est lu puis jeté : le fils ne
/// se bloque jamais sur un tube plein). Délai : SIGTERM, puis SIGKILL deux secondes après.
enum BoundedProcessRunner {
    static func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval, maxOutputBytes: Int
    ) async -> RemoteExecResult {
        await withCheckedContinuation { (cont: CheckedContinuation<RemoteExecResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(
                    executable: executable, arguments: arguments, environment: environment,
                    timeout: timeout, maxOutputBytes: maxOutputBytes))
            }
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval, maxOutputBytes: Int
    ) -> RemoteExecResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, n in n }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return RemoteExecResult(failure: "lancement de ssh impossible : \(error)")
        }
        let outBox = Locked((Data(), false)), errBox = Locked((Data(), false))
        let group = DispatchGroup()
        let ref = ProcessRef(p)
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            Thread.detachNewThread {
                // Lecture par poll : quand ssh meurt (délai), le maître garde les descripteurs reçus du client
                // mux et le tube ne se ferme qu'à la fin de la commande distante ; on s'arrête donc à la mort
                // du processus plutôt qu'à la fin de fichier.
                let fd = pipe.fileHandleForReading.fileDescriptor
                var buf = [UInt8](repeating: 0, count: 16 * 1024)
                var drained = 0
                while true {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let n = poll(&pfd, 1, 100)
                    if n > 0 {
                        let r = read(fd, &buf, buf.count)
                        if r <= 0 { break }
                        box.with { b in
                            let room = maxOutputBytes - b.0.count
                            if r <= room { b.0.append(contentsOf: buf[0..<r]) } else {
                                if room > 0 { b.0.append(contentsOf: buf[0..<room]) }
                                b.1 = true
                            }
                        }
                        drained = 0
                    } else if !ref.process.isRunning {
                        drained += 1
                        if drained >= 2 { break }
                    }
                }
                group.leave()
            }
        }
        let timedOut = Locked(false)
        let item = DispatchWorkItem {
            guard ref.process.isRunning else { return }
            timedOut.with { $0 = true }
            ref.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if ref.process.isRunning { kill(ref.process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        p.waitUntilExit()
        item.cancel()
        group.wait()
        let o = outBox.with { $0 }, e = errBox.with { $0 }
        let late = timedOut.with { $0 }
        return RemoteExecResult(
            exitCode: late ? nil : p.terminationStatus,
            stdout: String(decoding: o.0, as: UTF8.self), stderr: String(decoding: e.0, as: UTF8.self),
            stdoutTruncated: o.1, stderrTruncated: e.1, timedOut: late)
    }
}
