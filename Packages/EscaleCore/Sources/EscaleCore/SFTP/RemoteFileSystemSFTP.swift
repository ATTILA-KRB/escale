import Foundation

// `SFTPClient` comme `RemoteFileSystem` : lecture/écriture par blocs, copie, et ouverture avec repli sur le shell.

extension SFTPClient: RemoteFileSystem {
    public nonisolated var kind: RemoteFileSystemKind { .sftp }

    public func canonicalPath(_ path: Data) async throws -> String { try await realpath(path) }

    public func attributes(of path: Data, followLinks: Bool) async throws -> SFTPAttributes {
        followLinks ? try await stat(path) : try await lstat(path)
    }

    public func listEntries(in path: Data) async throws -> [SFTPDirectoryEntry] { try await listDirectory(path) }
    public func makeDirectory(_ path: Data) async throws { try await mkdir(path) }
    public func removeDirectory(_ path: Data) async throws { try await rmdir(path) }
    public func removeFile(_ path: Data) async throws { try await remove(path) }
    public func renameItem(_ from: Data, to: Data) async throws { try await rename(from, to: to) }
    public func discardPartialUpload(at path: Data) async { try? await remove(path) }

    public func readBlock(_ path: Data, offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let handle = try expectHandle(try await call(SFTPPacket.open) { $0.bytes(path); $0.u32(0x1); $0.u32(0) })
        do {
            let out = try await readRange(handle: handle, offset: offset, length: length)
            try await closeHandle(handle, ignoringErrors: true)
            return out
        } catch {
            try? await closeHandle(handle, ignoringErrors: true)
            throw error
        }
    }

    /// Lit `length` octets (moins en fin de fichier), requête après requête.
    func readRange(handle: Data, offset: UInt64, length: Int) async throws -> Data {
        var out = Data()
        while out.count < length {
            let off = offset + UInt64(out.count), want = min(readChunk, length - out.count)
            let resp = try await call(SFTPPacket.read) { $0.bytes(handle); $0.u64(off); $0.u32(UInt32(want)) }
            if resp.type == SFTPPacket.status {
                if let e = try Self.statusError(resp) { if case .status(.eof, _) = e { break }; throw e }
                throw SFTPError.protocolViolation("OK inattendu pour READ")
            }
            guard resp.type == SFTPPacket.data else { throw SFTPError.protocolViolation("DATA attendu, reçu \(resp.type)") }
            var r = SFTPReader(resp.payload)
            let d = try r.bytes()
            guard !d.isEmpty, d.count <= want else { throw SFTPError.protocolViolation("lecture vide ou trop grande") }
            out.append(d)
        }
        return out
    }

    public func writeBlock(_ path: Data, offset: UInt64, data: Data, truncate: Bool) async throws {
        let flags: UInt32 = 0x2 | 0x8 | ((truncate && offset == 0) ? 0x10 : 0)
        let handle = try expectHandle(try await call(SFTPPacket.open) {
            $0.bytes(path); $0.u32(flags); $0.attrs(permissions: 0o644, accessTime: nil, modificationTime: nil)
        })
        do {
            try await writeRange(handle: handle, offset: offset, data: data)
            try await closeHandle(handle, ignoringErrors: false)
        } catch {
            try? await closeHandle(handle, ignoringErrors: true)
            throw error
        }
    }

    func writeRange(handle: Data, offset: UInt64, data: Data) async throws {
        var done = 0
        while done < data.count {
            let n = min(writeChunk, data.count - done)
            let piece = data.subdata(in: (data.startIndex + done)..<(data.startIndex + done + n))
            let off = offset + UInt64(done)
            try expectOK(try await call(SFTPPacket.write) { $0.bytes(handle); $0.u64(off); $0.bytes(piece) })
            done += n
        }
    }

    public func copyItem(from: Data, to: Data) async throws {
        let attrs = try await stat(from)
        switch attrs.type {
        case .directory:
            try await mkdir(to, permissions: attrs.permissionBits ?? 0o755)
            for e in try await listDirectory(from) where e.type != .other {
                try await copyItem(from: from.remoteJoined(e.nameBytes), to: to.remoteJoined(e.nameBytes))
            }
        default:
            try await copyFile(from: from, to: to, permissions: attrs.permissionBits ?? 0o644)
        }
    }

    /// Copie un fichier par lecture puis écriture (le serveur ne passe par aucun shell).
    func copyFile(from: Data, to: Data, permissions: UInt32) async throws {
        let src = try expectHandle(try await call(SFTPPacket.open) { $0.bytes(from); $0.u32(0x1); $0.u32(0) })
        let dst: Data
        do {
            dst = try expectHandle(try await call(SFTPPacket.open) {
                $0.bytes(to); $0.u32(0x2 | 0x8 | 0x20); $0.attrs(permissions: permissions, accessTime: nil, modificationTime: nil)
            })
        } catch { try? await closeHandle(src, ignoringErrors: true); throw error }
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let block = try await readRange(handle: src, offset: offset, length: readChunk)
                if block.isEmpty { break }
                try await writeRange(handle: dst, offset: offset, data: block)
                offset += UInt64(block.count)
            }
            try await closeHandle(src, ignoringErrors: true)
            try await closeHandle(dst, ignoringErrors: false)
        } catch {
            try? await closeHandle(src, ignoringErrors: true)
            try? await closeHandle(dst, ignoringErrors: true)
            throw error
        }
    }
}

/// Résultat de l'ouverture d'un système de fichiers distant.
public struct RemoteFileSystemOpening: Sendable {
    public let fileSystem: any RemoteFileSystem
    public var kind: RemoteFileSystemKind { fileSystem.kind }
    /// Raison du repli sur le shell (nil en SFTP).
    public let fallbackReason: String?
}

public enum RemoteFileSystemOpener {
    /// Erreurs qui signifient « le serveur ne propose pas de SFTP » (par opposition à une connexion perdue ou saturée).
    static func isSubsystemRefusal(_ error: any Error) -> Bool {
        if case SSHTransportError.subsystemUnavailable = error { return true }
        if let e = error as? SFTPError {
            switch e {
            case .channelClosed, .negotiationTimeout, .unsupportedVersion, .protocolViolation: return true
            default: return false
            }
        }
        return false
    }

    /// Ouvre le SFTP ; si le serveur le refuse mais accepte `exec`, bascule sur `ShellFileSystem`.
    /// `forceShell` saute l'essai SFTP (déjà échoué plus tôt sur cette connexion).
    /// Lève `notConnected` / `sessionRefused` (lien perdu ou plein : à traiter par l'appelant, pas un refus de SFTP).
    public static func open(transport: OpenSSHTransport, forceShell: Bool = false,
                            configuration: SFTPClientConfiguration = .init()) async throws -> RemoteFileSystemOpening {
        var reason = "ouverture du shell demandée"
        var sftpError: (any Error)?
        if !forceShell {
            do {
                let channel = try await transport.openSFTPChannel()
                let client = try await SFTPClient.connect(channel: channel, configuration: configuration)
                return RemoteFileSystemOpening(fileSystem: client, fallbackReason: nil)
            } catch {
                guard isSubsystemRefusal(error) else { throw error }
                reason = SFTPErrorText.describe(error)
                sftpError = error
            }
        }
        // Le shell doit répondre : sinon on rend l'erreur SFTP d'origine (ou celle du shell si on l'a forcé).
        let probe: RemoteExecResult
        do { probe = try await transport.exec("echo escale-shell-ok", timeout: 15, maxOutputBytes: 1024) }
        catch { throw error }
        guard probe.isSuccess, probe.stdout.contains("escale-shell-ok") else {
            throw sftpError ?? SFTPError.status(.opUnsupported, message: "exécution de commandes refusée par le serveur")
        }
        return RemoteFileSystemOpening(fileSystem: ShellFileSystem(executor: transport), fallbackReason: reason)
    }
}

enum SFTPErrorText {
    static func describe(_ error: any Error) -> String {
        switch error {
        case SSHTransportError.subsystemUnavailable(let m): return m
        case SFTPError.channelClosed(let m): return m
        case SFTPError.negotiationTimeout: return "le serveur SFTP ne répond pas"
        default: return String(describing: error)
        }
    }
}
