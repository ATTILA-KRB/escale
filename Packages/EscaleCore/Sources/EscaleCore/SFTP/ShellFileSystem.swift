import CryptoKit
import Foundation

/// `RemoteFileSystem` au-dessus de commandes shell (sessions exec du maître) pour les serveurs qui refusent le
/// sous-système SFTP. Hypothèse : le serveur distant offre un `/bin/sh` POSIX et les outils usuels (`ls`/`find`/`stat`,
/// `cat`, `dd`, `mv`, `cp`, `mkdir`, `rm`). Aucun chemin n'est jamais interpolé dans un script (voir `ShellQuote`).
///
/// Limites : noms non UTF-8 non adressables ; listage `ls` (dernier recours) sans retour à la ligne dans les noms ;
/// reprise d'un téléchargement alignée sur 64 Kio ; un envoi s'écrit dans `<fichier>.part`, renommé à la fin.
public actor ShellFileSystem: RemoteFileSystem {
    public nonisolated var kind: RemoteFileSystemKind { .shell }

    let executor: any ShellExecutor
    private let forcedTier: ShellListingTier?
    private var tier: ShellListingTier?
    /// Délai d'une commande de métadonnées (un listage de gros dossier sur lien lent peut être long).
    let commandTimeout: TimeInterval
    static let blockSize = 64 * 1024

    public init(executor: any ShellExecutor, forcedTier: ShellListingTier? = nil, commandTimeout: TimeInterval = 60) {
        self.executor = executor
        self.forcedTier = forcedTier
        self.commandTimeout = commandTimeout
    }

    /// Méthode de listage retenue (nil avant le premier listage).
    public var listingTier: ShellListingTier? { tier }

    public func close() async {}

    // MARK: - Exécution

    /// Exécute un script constant avec ses arguments ; renvoie la sortie ou l'erreur SFTP équivalente.
    func run(_ script: String, _ args: [String], maxOutput: Int = 64 * 1024 * 1024) async throws -> RemoteExecResult {
        let r = try await executor.runShell(ShellQuote.command(script: script, args: args), timeout: commandTimeout, maxOutputBytes: maxOutput)
        if !r.isSuccess { throw Self.error(from: r) }
        if r.stdoutTruncated { throw SFTPError.protocolViolation("sortie distante trop volumineuse") }
        return r
    }

    static func error(from r: RemoteExecResult) -> SFTPError {
        if let f = r.failure { return .channelClosed(f) }
        if r.timedOut { return .requestTimeout(seconds: r.duration) }
        return error(stderr: r.stderr, exitCode: r.exitCode)
    }

    static func error(stderr: String, exitCode: Int32?) -> SFTPError {
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = msg.lowercased()
        if exitCode == 255 { return .channelClosed(msg.isEmpty ? "ssh a échoué (code 255)" : msg) }
        if exitCode == 126 || exitCode == 127 || l.contains("command not found") { return .status(.opUnsupported, message: msg) }
        if l.contains("no such file") { return .status(.noSuchFile, message: msg) }
        if l.contains("permission denied") || l.contains("operation not permitted") { return .status(.permissionDenied, message: msg) }
        return .status(.failure, message: msg.isEmpty ? "la commande distante a échoué (code \(exitCode.map(String.init) ?? "?"))" : msg)
    }

    /// Message d'une méthode de listage inconnue du serveur (on passe à la suivante).
    static func isUnsupported(_ r: RemoteExecResult) -> Bool {
        if r.failure != nil || r.timedOut { return false }
        let l = r.stderr.lowercased()
        return ["unknown primary", "unknown predicate", "unrecognized option", "illegal option", "invalid option",
                "unknown option", "bad option", "not found", "usage:"].contains { l.contains($0) }
            || r.exitCode == 126 || r.exitCode == 127
    }

    private func candidates() -> [ShellListingTier] {
        if let f = forcedTier { return [f] }
        if let t = tier { return [t] + ShellListingTier.allCases.filter { $0 != t } }
        return ShellListingTier.allCases
    }

    /// Essaie chaque méthode de listage jusqu'à ce que l'une soit comprise du serveur, puis la retient.
    private func withTier<T>(script: (ShellListingTier) -> String, args: [String],
                             parse: (ShellListingTier, RemoteExecResult) throws -> T) async throws -> T {
        var last: SFTPError = .status(.opUnsupported, message: "aucune méthode de listage disponible")
        for t in candidates() {
            let r = try await executor.runShell(ShellQuote.command(script: script(t), args: args),
                                                timeout: commandTimeout, maxOutputBytes: 64 * 1024 * 1024)
            if r.isSuccess {
                if r.stdoutTruncated { throw SFTPError.protocolViolation("listage trop volumineux") }
                let value = try parse(t, r)
                tier = t
                return value
            }
            if forcedTier == nil, Self.isUnsupported(r) { last = Self.error(from: r); continue }
            throw Self.error(from: r)
        }
        throw last
    }

    private static func records(_ t: ShellListingTier, _ r: RemoteExecResult) throws -> [ShellRecord] {
        switch t {
        case .gnuFind: try ShellParsers.gnuFind(r.stdout)
        case .statLoop: try ShellParsers.statLoop(r.stdout)
        case .ls: ShellParsers.ls(r.stdout)
        }
    }

    // MARK: - RemoteFileSystem

    public func canonicalPath(_ path: Data) async throws -> String {
        let r = try await run(ShellScripts.realpath, [try ShellQuote.path(path)])
        var s = r.stdout
        if s.hasSuffix("\n") { s.removeLast() }
        guard s.hasPrefix("/") else { throw SFTPError.protocolViolation("chemin canonique invalide : \(s)") }
        return s
    }

    public func attributes(of path: Data, followLinks: Bool) async throws -> SFTPAttributes {
        let p = try ShellQuote.path(path)
        let recs = try await withTier(script: ShellScripts.stat, args: [p, followLinks ? "1" : "0"]) { try Self.records($0, $1) }
        guard let first = recs.first else { throw SFTPError.status(.noSuchFile, message: "introuvable") }
        return first.entry.attributes
    }

    public func listEntries(in path: Data) async throws -> [SFTPDirectoryEntry] {
        let p = try ShellQuote.path(path)
        let recs = try await withTier(script: ShellScripts.list, args: [p]) { try Self.records($0, $1) }
        return recs.filter { $0.name != Data(".".utf8) && $0.name != Data("..".utf8) }.map(\.entry)
    }

    public func makeDirectory(_ path: Data) async throws { _ = try await run(ShellScripts.makeDirectory, [try ShellQuote.path(path)]) }
    public func removeDirectory(_ path: Data) async throws { _ = try await run(ShellScripts.removeDirectory, [try ShellQuote.path(path)]) }
    public func removeFile(_ path: Data) async throws { _ = try await run(ShellScripts.removeFile, [try ShellQuote.path(path)]) }

    public func renameItem(_ from: Data, to: Data) async throws {
        _ = try await run(ShellScripts.rename, [try ShellQuote.path(from), try ShellQuote.path(to)])
    }

    public func copyItem(from: Data, to: Data) async throws {
        _ = try await run(ShellScripts.copy, [try ShellQuote.path(from), try ShellQuote.path(to)])
    }

    /// Ouvre un flux, applique `body`, puis attend la fin ; le code de sortie non nul devient une erreur.
    private func withStream<T: Sendable>(_ script: String, _ args: [String],
                                         _ body: @Sendable (RemoteExecStream) async throws -> T) async throws -> T {
        let stream = try await executor.openShellStream(ShellQuote.command(script: script, args: args))
        let value: T
        do {
            value = try await withTaskCancellationHandler { try await body(stream) } onCancel: { stream.cancel() }
        } catch {
            throw await Self.streamFailure(stream, error, cancelledLocal: nil, bytes: 0)
        }
        let (code, err) = await stream.finish()
        guard code == 0 else { throw Self.error(stderr: err, exitCode: code) }
        return value
    }

    public func readBlock(_ path: Data, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let p = try ShellQuote.path(path)
        let bs: UInt64 = 4096
        let first = offset / bs
        let skipBytes = Int(offset - first * bs)
        let count = (UInt64(skipBytes + length) + bs - 1) / bs
        let raw = try await withStream(ShellScripts.readBlock, [p, String(first), String(count)]) { try await $0.readAll() }
        guard raw.count > skipBytes else { return Data() }
        return Data(raw.dropFirst(skipBytes).prefix(length))
    }

    public func writeBlock(_ path: Data, offset: UInt64, data: Data, truncate: Bool) async throws {
        let p = try ShellQuote.path(path)
        let (script, args): (String, [String]) = (truncate && offset == 0)
            ? (ShellScripts.writeBlockTruncate, [p]) : (ShellScripts.writeBlockAt, [p, String(offset)])
        try await withStream(script, args) { s in
            try await s.write(data)
            await s.closeInput()
        }
    }

    public func discardPartialUpload(at path: Data) async {
        try? await removeFile(path + Data(".part".utf8))
    }

    // MARK: - Transferts

    public nonisolated func startDownload(remotePath: Data, to localURL: URL, resume: Bool,
                                          verification: SFTPResumeVerification) -> SFTPTransferTask {
        SFTPTransferTask.launch { observer in
            do {
                var from: UInt64 = 0
                var reason: String?
                if resume { (from, reason) = try await self.decideDownloadResume(remotePath, localURL, verification) }
                let n = try await self.runDownload(remotePath, localURL, resumeFrom: from, observer: observer)
                return SFTPTransferOutcome(totalBytes: n, resumedFrom: from, restartReason: reason)
            } catch is CancellationError {
                throw SFTPError.cancelled(partialLocalFile: localURL, bytesTransferred: 0)
            }
        }
    }

    public nonisolated func startUpload(localURL: URL, to remotePath: Data, resume: Bool,
                                        verification: SFTPResumeVerification) -> SFTPTransferTask {
        SFTPTransferTask.launch { observer in
            do {
                var from: UInt64 = 0
                var reason: String?
                if resume { (from, reason) = try await self.decideUploadResume(localURL, remotePath, verification) }
                let n = try await self.runUpload(localURL, remotePath, resumeFrom: from, observer: observer)
                return SFTPTransferOutcome(totalBytes: n, resumedFrom: from, restartReason: reason)
            } catch is CancellationError {
                throw SFTPError.cancelled(partialLocalFile: nil, bytesTransferred: 0)
            }
        }
    }

    // MARK: Reprise vérifiée

    private func localSize(_ url: URL) -> UInt64? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular,
              let n = a[.size] as? NSNumber else { return nil }
        return n.uint64Value
    }

    /// Compare le préfixe de `length` octets (échantillons ou tout) du fichier local et du fichier distant.
    private func prefixMatches(local: URL, remote: Data, length: UInt64, verification: SFTPResumeVerification) async throws -> Bool {
        let fd = open(local.path, O_RDONLY)
        guard fd >= 0 else { throw localError("ouverture de \(local.path)") }
        defer { Darwin.close(fd) }
        for range in SFTPClient.verificationRanges(length: length, verification) {
            var offset = range.lowerBound
            while offset < range.upperBound {
                try Task.checkCancellation()
                let n = Int(min(1 << 20, range.upperBound - offset))
                let mine = try preadExact(fd, count: n, at: offset)
                let theirs = try await readBlock(remote, offset: offset, length: n)
                if mine != theirs { return false }
                offset += UInt64(n)
            }
        }
        return true
    }

    func decideDownloadResume(_ path: Data, _ localURL: URL, _ v: SFTPResumeVerification) async throws -> (UInt64, String?) {
        guard let local = localSize(localURL), local > 0 else { return (0, nil) }
        let remote: UInt64
        do { remote = try await attributes(of: path, followLinks: true).size ?? 0 }
        catch SFTPError.status(.noSuchFile, _) { return (0, nil) }
        guard local <= remote else { return (0, "fichier local (\(local) o) plus grand que le fichier distant (\(remote) o)") }
        let keep = local / UInt64(Self.blockSize) * UInt64(Self.blockSize)
        if keep == 0 { return (0, nil) }
        let ok = try await prefixMatches(local: localURL, remote: path, length: keep, verification: v)
        return ok ? (keep, nil) : (0, "le début du fichier local diffère du fichier distant")
    }

    func decideUploadResume(_ localURL: URL, _ path: Data, _ v: SFTPResumeVerification) async throws -> (UInt64, String?) {
        let part = path + Data(".part".utf8)
        let remote: UInt64
        do { remote = try await attributes(of: part, followLinks: false).size ?? 0 }
        catch SFTPError.status(.noSuchFile, _) { return (0, nil) }
        if remote == 0 { return (0, nil) }
        guard let local = localSize(localURL) else { throw SFTPError.localIO("ouverture de \(localURL.path) impossible") }
        guard remote <= local else { return (0, "fichier distant (\(remote) o) plus grand que le fichier local (\(local) o)") }
        let ok = try await prefixMatches(local: localURL, remote: part, length: remote, verification: v)
        return ok ? (remote, nil) : (0, "le début du fichier distant diffère du fichier local")
    }

    // MARK: Flux

    func runDownload(_ path: Data, _ localURL: URL, resumeFrom: UInt64,
                     observer: (@Sendable (SFTPTransferSnapshot) -> Void)?) async throws -> UInt64 {
        precondition(resumeFrom % UInt64(Self.blockSize) == 0)
        let p = try ShellQuote.path(path)
        let total = try? await attributes(of: path, followLinks: true).size
        let fd = open(localURL.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw localError("ouverture de \(localURL.path)") }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        fstat(fd, &st)
        if resumeFrom > 0 {
            guard UInt64(st.st_size) >= resumeFrom else {
                throw SFTPError.invalidResumeOffset("fichier local (\(st.st_size) o) plus court que l'offset \(resumeFrom)")
            }
        }
        guard ftruncate(fd, off_t(resumeFrom)) == 0 else { throw localError("troncature") }
        if let total, resumeFrom > total { throw SFTPError.invalidResumeOffset("offset \(resumeFrom) > taille distante \(total)") }

        let stream = try await executor.openShellStream(ShellQuote.command(
            script: ShellScripts.download, args: [p, String(resumeFrom / UInt64(Self.blockSize))]))
        var meter = SFTPTransferMeter(configuration: SFTPClientConfiguration())
        var done = resumeFrom
        observer?(meter.snapshot(done: done, total: total))
        do {
            try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    let data = try await stream.read(maxBytes: 256 * 1024)
                    if data.isEmpty { break }
                    try Self.pwriteAll(fd, data, at: done)
                    done += UInt64(data.count)
                    meter.advance(bytes: data.count, done: done)
                    if let o = observer, let snap = meter.snapshotIfDue(done: done, total: total) { o(snap) }
                }
            } onCancel: { stream.cancel() }
        } catch {
            throw await Self.streamFailure(stream, error, cancelledLocal: localURL, bytes: done)
        }
        let (code, err) = await stream.finish()
        guard code == 0 else { throw Self.error(stderr: err, exitCode: code) }
        if let total, done != total { throw SFTPError.channelClosed("flux interrompu : \(done) o reçus sur \(total)") }
        observer?(meter.snapshot(done: done, total: total ?? done))
        return done
    }

    func runUpload(_ localURL: URL, _ path: Data, resumeFrom: UInt64,
                   observer: (@Sendable (SFTPTransferSnapshot) -> Void)?) async throws -> UInt64 {
        let p = try ShellQuote.path(path)
        let fd = open(localURL.path, O_RDONLY)
        guard fd >= 0 else { throw localError("ouverture de \(localURL.path)") }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0 else { throw localError("fstat") }
        let size = UInt64(st.st_size)
        guard resumeFrom <= size else { throw SFTPError.invalidResumeOffset("offset \(resumeFrom) > taille locale \(size)") }
        let mode = String(UInt32(st.st_mode) & 0o777, radix: 8)
        var meter = SFTPTransferMeter(configuration: SFTPClientConfiguration())
        var done = resumeFrom
        observer?(meter.snapshot(done: done, total: size))

        if resumeFrom < size || resumeFrom == 0 {
            let stream = try await executor.openShellStream(ShellQuote.command(
                script: ShellScripts.upload, args: [p, resumeFrom > 0 ? "append" : "new"]))
            do {
                try await withTaskCancellationHandler {
                    var offset = resumeFrom
                    while offset < size {
                        try Task.checkCancellation()
                        let n = Int(min(UInt64(Self.blockSize), size - offset))
                        try await stream.write(try preadExact(fd, count: n, at: offset))
                        offset += UInt64(n); done = offset
                        meter.advance(bytes: n, done: done)
                        if let o = observer, let snap = meter.snapshotIfDue(done: done, total: size) { o(snap) }
                    }
                    await stream.closeInput()
                } onCancel: { stream.cancel() }
            } catch {
                throw await Self.streamFailure(stream, error, cancelledLocal: nil, bytes: done)
            }
            let (code, err) = await stream.finish()
            guard code == 0 else { throw Self.error(stderr: err, exitCode: code) }
        }
        // Ne remplace le fichier final qu'une fois tous les octets arrivés (jamais un fichier tronqué).
        let received = try await attributes(of: path + Data(".part".utf8), followLinks: false).size ?? 0
        guard received == size else { throw SFTPError.channelClosed("envoi incomplet : \(received) o reçus sur \(size)") }
        _ = try await run(ShellScripts.finishUpload, [p, mode])
        observer?(meter.snapshot(done: size, total: size))
        return size
    }

    /// Erreur à remonter quand un flux casse. Une commande qui échoue tout de suite (dossier absent, droits) ferme son
    /// stdin : l'écriture échoue alors en EPIPE, mais la vraie cause est le message de la commande, pas « lien perdu ».
    static func streamFailure(_ stream: RemoteExecStream, _ error: any Error, cancelledLocal: URL?, bytes: UInt64) async -> any Error {
        if error is CancellationError || Task.isCancelled {
            stream.cancel()
            _ = await stream.finish(timeout: 5)
            return SFTPError.cancelled(partialLocalFile: cancelledLocal, bytesTransferred: bytes)
        }
        guard let e = error as? ByteChannelError, case .closed(let reason) = e else {
            stream.cancel(); _ = await stream.finish(timeout: 5); return error
        }
        let (code, err) = await stream.finish(timeout: 5)
        if let code, code != 0, code != 255 || !err.isEmpty { return Self.error(stderr: err, exitCode: code) }
        return SFTPError.channelClosed(reason)
    }

    private static func pwriteAll(_ fd: Int32, _ data: Data, at offset: UInt64) throws {
        try data.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(offset) + off_t(done))
                if n > 0 { done += n } else if n < 0 && errno == EINTR { continue } else { throw localError("écriture locale") }
            }
        }
    }
}

extension SFTPTransferTask {
    /// Lance `body` en tâche suivie (flux d'instantanés ne retenant que le dernier).
    static func launch(_ body: @escaping @Sendable (@escaping @Sendable (SFTPTransferSnapshot) -> Void) async throws -> SFTPTransferOutcome) -> SFTPTransferTask {
        let (stream, continuation) = AsyncStream<SFTPTransferSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task<SFTPTransferOutcome, any Error> {
            defer { continuation.finish() }
            return try await body { continuation.yield($0) }
        }
        return SFTPTransferTask(progress: stream, task: task)
    }
}
