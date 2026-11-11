import Foundation

/// Résultat d'un ssh de courte durée (`-O check`, `-O forward`…).
struct OpenSSHRunResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    /// Texte combiné, nettoyé, pour les messages d'erreur.
    var combined: String { (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Boîte partagée entre threads, protégée par un verrou.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ p: Process) { process = p }
}

/// Lance un processus court et attend sa fin SANS occuper un thread du pool coopératif
/// (le travail bloquant tourne sur une file GCD).
enum OpenSSHProcessRunner {
    static func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async -> OpenSSHRunResult {
        await withCheckedContinuation { (cont: CheckedContinuation<OpenSSHRunResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
            }
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) -> OpenSSHRunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return OpenSSHRunResult(status: -1, stdout: "", stderr: "lancement impossible : \(error)", timedOut: false)
        }
        let outData = LockedBox(Data()), errData = LockedBox(Data())
        let group = DispatchGroup()
        for (pipe, box) in [(out, outData), (err, errData)] {
            group.enter()
            Thread.detachNewThread {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                box.with { $0 = d }
                group.leave()
            }
        }
        let timedOut = LockedBox(false)
        let pb = ProcessBox(p)
        let item = DispatchWorkItem {
            if pb.process.isRunning { timedOut.with { $0 = true }; pb.process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        p.waitUntilExit()
        item.cancel()
        group.wait()
        return OpenSSHRunResult(
            status: p.terminationStatus,
            stdout: String(decoding: outData.with { $0 }, as: UTF8.self),
            stderr: String(decoding: errData.with { $0 }, as: UTF8.self),
            timedOut: timedOut.with { $0 })
    }
}

/// Sonde TCP locale : prouve réellement qu'un port écoute (ou n'écoute plus).
enum OpenSSHPortProbe {
    enum Outcome: Equatable, Sendable {
        /// Connexion impossible (rien n'écoute).
        case closed
        /// Connexion acceptée et non rejetée pendant la fenêtre d'observation.
        case open
        /// Connexion acceptée puis fermée aussitôt : ssh a accepté la connexion locale mais le canal a été rejeté.
        case rejected
    }

    static func probe(host: String, port: Int, observe: TimeInterval) async -> Outcome {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: probeBlocking(host: host, port: port, observe: observe))
            }
        }
    }

    private static func probeBlocking(host: String, port: Int, observe: TimeInterval) -> Outcome {
        // Une adresse d'écoute générique se sonde via le loopback.
        let bare = TunnelSpec.unbracketed(host)
        let target = (bare.isEmpty || bare == "*" || bare == "0.0.0.0") ? "127.0.0.1" : (bare == "::" ? "::1" : bare)
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target, String(port), &hints, &res) == 0, let first = res else { return .closed }
        defer { freeaddrinfo(res) }
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            cur = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { continue }
            defer { close(fd) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 { continue }
            if observe <= 0 { return .open }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, Int32(observe * 1000))
            if n <= 0 { return .open }
            var b: UInt8 = 0
            let r = recv(fd, &b, 1, 0)
            return r > 0 ? .open : .rejected
        }
        return .closed
    }
}

/// Résumé lisible d'un journal ssh (stderr du maître ou d'un client).
enum OpenSSHJournal {
    private static let noise = ["debug1:", "debug2:", "debug3:", "OpenSSH_", "Warning: Permanently added", "Pseudo-terminal will not"]
    private static let hints = [
        "denied", "refused", "failed", "error", "could not", "no route", "timed out", "not known", "closed by",
        "no such file", "cannot", "unable", "invalid", "administratively prohibited", "mismatch", "changed",
    ]

    /// Lignes utiles (sans le bruit `debug1:`).
    static func meaningfulLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !noise.contains { line.hasPrefix($0) } }
    }

    /// Dernier message d'erreur : de préférence une ligne qui ressemble à une erreur, sinon la dernière ligne.
    static func lastError(_ text: String) -> String? {
        let lines = meaningfulLines(text)
        return lines.last { l in hints.contains { l.lowercased().contains($0) } } ?? lines.last
    }
}
