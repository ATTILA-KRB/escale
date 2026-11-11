import CryptoKit
import Foundation

// Reprise vérifiée : avant de reprendre un transfert interrompu, on s'assure que ce qui est déjà en place est bien le
// début du fichier source. Sinon on recommence de zéro (jamais de fichier mélangeant deux versions).
//
// SFTP v3 n'a pas d'empreinte côté serveur (OpenSSH n'implémente pas `check-file`) : on relit donc les octets
// distants et on compare des SHA-256 calculés localement.

extension SFTPClient {

    /// Télécharge avec reprise automatique : repart de la taille du fichier local partiel si son contenu est bien le début
    /// du fichier distant (têtes et queues comparées par SHA-256, ou intégralité avec `.full`), sinon recommence de zéro.
    /// - Parameter observer: instantanés de progression (≈ 10/s, débit lissé, fenêtre courante).
    public func downloadResuming(remotePath: some SFTPPathRepresentable, to localURL: URL,
                                 verification: SFTPResumeVerification = .default,
                                 progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil,
                                 observer: (@Sendable (SFTPTransferSnapshot) -> Void)? = nil) async throws -> SFTPTransferOutcome {
        let path = remotePath.sftpBytes
        var resume: UInt64 = 0
        var reason: String?
        if let local = Self.localSize(localURL), local > 0 {
            (resume, reason) = try await verifiedDownloadOffset(path: path, localURL: localURL, localSize: local, verification: verification)
        }
        let total = try await runDownload(path: path, to: localURL, resumeFrom: resume, progress: progress, observer: observer)
        return SFTPTransferOutcome(totalBytes: total, resumedFrom: resume, restartReason: reason)
    }

    /// Envoie avec reprise automatique : repart de la taille du fichier distant partiel si son contenu est bien le début
    /// du fichier local, sinon recommence de zéro (le fichier distant est alors tronqué).
    public func uploadResuming(localURL: URL, to remotePath: some SFTPPathRepresentable,
                               verification: SFTPResumeVerification = .default,
                               progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil,
                               observer: (@Sendable (SFTPTransferSnapshot) -> Void)? = nil) async throws -> SFTPTransferOutcome {
        let path = remotePath.sftpBytes
        var resume: UInt64 = 0
        var reason: String?
        let remote: UInt64?
        do { remote = try await stat(path).size } catch SFTPError.status(.noSuchFile, _) { remote = nil }
        if let remote, remote > 0 {
            guard let local = Self.localSize(localURL) else { throw SFTPError.localIO("ouverture de \(localURL.path) impossible") }
            (resume, reason) = try await verifiedUploadOffset(path: path, localURL: localURL, localSize: local,
                                                              remoteSize: remote, verification: verification)
        }
        let total = try await runUpload(localURL: localURL, path: path, resumeFrom: resume, progress: progress, observer: observer)
        return SFTPTransferOutcome(totalBytes: total, resumedFrom: resume, restartReason: reason)
    }

    // MARK: - Décision de reprise

    private func verifiedDownloadOffset(path: Data, localURL: URL, localSize: UInt64,
                                        verification: SFTPResumeVerification) async throws -> (UInt64, String?) {
        let remote: UInt64
        do { remote = try await stat(path).size ?? 0 } catch SFTPError.status(.noSuchFile, _) { return (0, nil) }
        guard localSize <= remote else {
            return (0, "fichier local (\(localSize) o) plus grand que le fichier distant (\(remote) o)")
        }
        let fd = open(localURL.path, O_RDONLY)
        guard fd >= 0 else { throw localError("ouverture de \(localURL.path)") }
        defer { Darwin.close(fd) }
        let match = try await prefixMatches(path: path, fd: fd, length: localSize, verification: verification)
        return match ? (localSize, nil) : (0, "le début du fichier local diffère du fichier distant")
    }

    private func verifiedUploadOffset(path: Data, localURL: URL, localSize: UInt64, remoteSize: UInt64,
                                      verification: SFTPResumeVerification) async throws -> (UInt64, String?) {
        guard remoteSize <= localSize else {
            return (0, "fichier distant (\(remoteSize) o) plus grand que le fichier local (\(localSize) o)")
        }
        let fd = open(localURL.path, O_RDONLY)
        guard fd >= 0 else { throw localError("ouverture de \(localURL.path)") }
        defer { Darwin.close(fd) }
        let match = try await prefixMatches(path: path, fd: fd, length: remoteSize, verification: verification)
        return match ? (remoteSize, nil) : (0, "le début du fichier distant diffère du fichier local")
    }

    private static func localSize(_ url: URL) -> UInt64? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular,
              let n = a[.size] as? NSNumber else { return nil }
        return n.uint64Value
    }

    /// Plages à comparer pour un préfixe de `length` octets.
    static func verificationRanges(length: UInt64, _ v: SFTPResumeVerification) -> [Range<UInt64>] {
        guard length > 0 else { return [] }
        switch v {
        case .full: return [0..<length]
        case .sample(let head, let tail):
            let h = UInt64(max(0, head)), t = UInt64(max(0, tail))
            if h + t >= length { return [0..<length] }
            var out: [Range<UInt64>] = []
            if h > 0 { out.append(0..<h) }
            if t > 0 { out.append((length - t)..<length) }
            // Réglage dégénéré (0 et 0) : on compare au moins le dernier octet… un bloc de queue minimal.
            return out.isEmpty ? [(length - 1)..<length] : out
        }
    }

    /// Compare local (fd) et distant sur le préfixe `[0, length)`. Un fichier distant trop court = différent.
    private func prefixMatches(path: Data, fd: Int32, length: UInt64, verification: SFTPResumeVerification) async throws -> Bool {
        let handle = try expectHandle(try await call(SFTPPacket.open) { $0.bytes(path); $0.u32(0x1); $0.u32(0) })
        do {
            var same = true
            for range in Self.verificationRanges(length: length, verification) {
                let local = try Self.localDigest(fd: fd, range: range)
                let remote = try await remoteDigest(handle: handle, range: range)
                if remote == nil || remote! != local { same = false; break }
            }
            try await closeHandle(handle, ignoringErrors: true)
            return same
        } catch {
            try? await closeHandle(handle, ignoringErrors: true)
            throw error
        }
    }

    private static func localDigest(fd: Int32, range: Range<UInt64>) throws -> SHA256.Digest {
        var hasher = SHA256()
        var offset = range.lowerBound
        let piece: UInt64 = 1 << 20
        while offset < range.upperBound {
            try Task.checkCancellation()
            let n = Int(min(piece, range.upperBound - offset))
            hasher.update(data: try preadExact(fd, count: n, at: offset))
            offset += UInt64(n)
        }
        return hasher.finalize()
    }

    /// SHA-256 d'une plage distante, lue en flux avec quelques requêtes en vol. `nil` si le fichier distant s'arrête avant.
    func remoteDigest(handle: Data, range: Range<UInt64>) async throws -> SHA256.Digest? {
        var hasher = SHA256()
        let chunk = readChunk
        var next = range.lowerBound
        var inflight: [(id: UInt32, offset: UInt64, length: Int)] = []
        var failed = false
        do {
            while next < range.upperBound || !inflight.isEmpty {
                try Task.checkCancellation()
                while next < range.upperBound && inflight.count < 16 {
                    let len = Int(min(UInt64(chunk), range.upperBound - next)), off = next
                    let id = try send(SFTPPacket.read) { $0.bytes(handle); $0.u64(off); $0.u32(UInt32(len)) }
                    inflight.append((id, off, len)); next += UInt64(len)
                }
                let req = inflight.removeFirst()
                let resp = try await receive(req.id)
                var data = Data()
                if resp.type == SFTPPacket.status {
                    if let e = try Self.statusError(resp), case .status(.eof, _) = e { failed = true; break }
                    else if let e = try Self.statusError(resp) { throw e }
                    throw SFTPError.protocolViolation("OK inattendu pour READ")
                }
                guard resp.type == SFTPPacket.data else { throw SFTPError.protocolViolation("DATA attendu, reçu \(resp.type)") }
                var r = SFTPReader(resp.payload)
                data = try r.bytes()
                guard data.count <= req.length else { throw SFTPError.protocolViolation("lecture plus grande que demandée") }
                while data.count < req.length {
                    let have = data.count, off = req.offset + UInt64(have), want = req.length - have
                    let r2 = try await call(SFTPPacket.read) { $0.bytes(handle); $0.u64(off); $0.u32(UInt32(want)) }
                    if r2.type == SFTPPacket.status { failed = true; break }
                    guard r2.type == SFTPPacket.data else { throw SFTPError.protocolViolation("DATA attendu, reçu \(r2.type)") }
                    var rr = SFTPReader(r2.payload)
                    let more = try rr.bytes()
                    guard !more.isEmpty, more.count <= want else { throw SFTPError.protocolViolation("lecture vide ou trop grande") }
                    data.append(more)
                }
                if failed { break }
                hasher.update(data: data)
            }
        } catch {
            for r in inflight { discard(r.id) }
            throw error
        }
        for r in inflight { discard(r.id) }
        return failed ? nil : hasher.finalize()
    }
}
