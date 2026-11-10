import Foundation

// Transferts en flux : fenêtre bornée de requêtes en vol, jamais le fichier entier en mémoire.

private func localError(_ what: String) -> SFTPError {
    SFTPError.localIO("\(what) : \(String(cString: strerror(errno))) (errno \(errno))")
}

private func pwriteAll(_ fd: Int32, _ data: Data, at offset: UInt64) throws {
    try data.withUnsafeBytes { buf in
        var done = 0
        while done < buf.count {
            let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(offset) + off_t(done))
            if n > 0 { done += n } else if n < 0 && errno == EINTR { continue } else { throw localError("écriture locale") }
        }
    }
}

private func preadExact(_ fd: Int32, count: Int, at offset: UInt64) throws -> Data {
    var data = Data(count: count)
    let got: Int = try data.withUnsafeMutableBytes { buf in
        var done = 0
        while done < count {
            let n = pread(fd, buf.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            if n > 0 { done += n } else if n == 0 { break } else if errno == EINTR { continue } else { throw localError("lecture locale") }
        }
        return done
    }
    guard got == count else { throw SFTPError.localIO("fichier local plus court que prévu (modifié pendant l'envoi ?)") }
    return data
}

extension SFTPClient {
    /// Télécharge `remotePath` vers `localURL` (créé sans être tronqué si `resumeFrom > 0`).
    /// - Parameter resumeFrom: reprend à cet offset ; le fichier local doit déjà faire au moins cette taille
    ///   (il est tronqué à cet offset). Ne vérifie PAS que le début local correspond au distant.
    /// - Returns: taille totale du fichier local à la fin.
    /// - Note: en cas d'annulation (Task) ou d'erreur, le fichier local partiel est laissé en place ;
    ///   `SFTPError.cancelled` le désigne. Le handle distant est fermé dans tous les cas.
    @discardableResult
    public func download(remotePath: some SFTPPathRepresentable, to localURL: URL, resumeFrom: UInt64 = 0,
                         progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil) async throws -> UInt64 {
        let path = remotePath.sftpBytes
        let total = try? await stat(path).size

        let fd = open(localURL.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw localError("ouverture de \(localURL.path)") }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        fstat(fd, &st)
        if resumeFrom == 0 {
            guard ftruncate(fd, 0) == 0 else { throw localError("troncature") }
        } else {
            guard UInt64(st.st_size) >= resumeFrom else {
                throw SFTPError.invalidResumeOffset("fichier local (\(st.st_size) o) plus court que l'offset \(resumeFrom)")
            }
            guard ftruncate(fd, off_t(resumeFrom)) == 0 else { throw localError("troncature") }
        }
        if let total, resumeFrom > total { throw SFTPError.invalidResumeOffset("offset \(resumeFrom) > taille distante \(total)") }

        let handle = try expectHandle(try await call(SFTPPacket.open) { $0.bytes(path); $0.u32(0x1); $0.u32(0) })
        let chunk = readChunk, window = max(1, configuration.window)
        var nextOffset = resumeFrom, done = resumeFrom
        var inflight: [(id: UInt32, offset: UInt64, length: Int)] = []
        var eof = false
        progress?(SFTPTransferProgress(bytesTransferred: done, totalBytes: total))
        do {
            while true {
                try Task.checkCancellation()
                while !eof && inflight.count < window && (total.map { nextOffset < $0 } ?? true) {
                    let len = total.map { Int(min(UInt64(chunk), $0 - nextOffset)) } ?? chunk
                    let off = nextOffset
                    let id = try send(SFTPPacket.read) { $0.bytes(handle); $0.u64(off); $0.u32(UInt32(len)) }
                    inflight.append((id, off, len))
                    nextOffset += UInt64(len)
                }
                guard !inflight.isEmpty else { break }
                let req = inflight.removeFirst()
                let resp = try await receive(req.id)
                var data = Data()
                if resp.type == SFTPPacket.status {
                    if let e = try Self.statusError(resp) {
                        if case .status(.eof, _) = e { eof = true } else { throw e }
                    } else { throw SFTPError.protocolViolation("OK inattendu pour READ") }
                } else {
                    guard resp.type == SFTPPacket.data else { throw SFTPError.protocolViolation("DATA attendu, reçu \(resp.type)") }
                    var r = SFTPReader(resp.payload)
                    data = try r.bytes()
                    guard data.count <= req.length else { throw SFTPError.protocolViolation("lecture plus grande que demandée") }
                    // Lecture courte sans EOF : on redemande le reste de la plage.
                    while data.count < req.length {
                        try Task.checkCancellation()
                        let have = data.count, off = req.offset + UInt64(have), want = req.length - have
                        let r2 = try await call(SFTPPacket.read) { $0.bytes(handle); $0.u64(off); $0.u32(UInt32(want)) }
                        if r2.type == SFTPPacket.status {
                            if let e = try Self.statusError(r2) {
                                if case .status(.eof, _) = e { eof = true; break } else { throw e }
                            }
                            throw SFTPError.protocolViolation("OK inattendu pour READ")
                        }
                        guard r2.type == SFTPPacket.data else { throw SFTPError.protocolViolation("DATA attendu, reçu \(r2.type)") }
                        var rr = SFTPReader(r2.payload)
                        let more = try rr.bytes()
                        guard !more.isEmpty, more.count <= want else { throw SFTPError.protocolViolation("lecture vide ou trop grande") }
                        data.append(more)
                    }
                }
                if !data.isEmpty {
                    try pwriteAll(fd, data, at: req.offset)
                    done += UInt64(data.count)
                    progress?(SFTPTransferProgress(bytesTransferred: done, totalBytes: total))
                }
            }
        } catch {
            for r in inflight { discard(r.id) }
            try? await closeHandle(handle, ignoringErrors: true)
            if error is CancellationError || Task.isCancelled {
                throw SFTPError.cancelled(partialLocalFile: localURL, bytesTransferred: done)
            }
            throw error
        }
        try await closeHandle(handle, ignoringErrors: false)
        return done
    }

    /// Envoie `localURL` vers `remotePath` (créé ; tronqué sauf si `resumeFrom > 0`).
    /// - Parameter resumeFrom: reprend à cet offset ; le fichier distant doit faire au moins cette taille.
    ///   Les octets distants au-delà de la fin du fichier local ne sont pas supprimés. Le début n'est pas comparé.
    /// - Returns: taille du fichier local.
    /// - Note: en cas d'annulation ou d'erreur, le fichier distant partiel reste sur le serveur ; le handle est fermé.
    @discardableResult
    public func upload(localURL: URL, to remotePath: some SFTPPathRepresentable, resumeFrom: UInt64 = 0,
                       progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil) async throws -> UInt64 {
        let path = remotePath.sftpBytes
        let fd = open(localURL.path, O_RDONLY)
        guard fd >= 0 else { throw localError("ouverture de \(localURL.path)") }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0 else { throw localError("fstat") }
        let size = UInt64(st.st_size)
        guard resumeFrom <= size else { throw SFTPError.invalidResumeOffset("offset \(resumeFrom) > taille locale \(size)") }
        if resumeFrom > 0 {
            let remoteSize = try await stat(path).size ?? 0
            guard remoteSize >= resumeFrom else {
                throw SFTPError.invalidResumeOffset("fichier distant (\(remoteSize) o) plus court que l'offset \(resumeFrom)")
            }
        }
        let flags: UInt32 = 0x2 | 0x8 | (resumeFrom == 0 ? 0x10 : 0)
        let mode = UInt32(st.st_mode) & 0o777
        let handle = try expectHandle(try await call(SFTPPacket.open) {
            $0.bytes(path); $0.u32(flags); $0.attrs(permissions: mode, accessTime: nil, modificationTime: nil)
        })
        let chunk = writeChunk, window = max(1, configuration.window)
        var offset = resumeFrom, done = resumeFrom
        var inflight: [(id: UInt32, length: Int)] = []
        progress?(SFTPTransferProgress(bytesTransferred: done, totalBytes: size))
        do {
            while offset < size {
                try Task.checkCancellation()
                if inflight.count >= window {
                    let req = inflight.removeFirst()
                    try expectOK(try await receive(req.id))
                    done += UInt64(req.length)
                    progress?(SFTPTransferProgress(bytesTransferred: done, totalBytes: size))
                }
                let len = Int(min(UInt64(chunk), size - offset))
                let data = try preadExact(fd, count: len, at: offset)
                let off = offset
                let id = try send(SFTPPacket.write) { $0.bytes(handle); $0.u64(off); $0.bytes(data) }
                inflight.append((id, len))
                offset += UInt64(len)
            }
            while !inflight.isEmpty {
                try Task.checkCancellation()
                let req = inflight.removeFirst()
                try expectOK(try await receive(req.id))
                done += UInt64(req.length)
                progress?(SFTPTransferProgress(bytesTransferred: done, totalBytes: size))
            }
        } catch {
            for r in inflight { discard(r.id) }
            try? await closeHandle(handle, ignoringErrors: true)
            if error is CancellationError || Task.isCancelled {
                throw SFTPError.cancelled(partialLocalFile: nil, bytesTransferred: done)
            }
            throw error
        }
        try await closeHandle(handle, ignoringErrors: false)
        return size
    }
}
